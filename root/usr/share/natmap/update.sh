#!/bin/bash
# 注意：本脚本由 natmap 按文件 shebang 直接执行，且会 source
# forward/link/notify 等 bash 脚本，必须保持 #!/bin/bash；
# bash 依赖由 natmap/luci-app-natmap 的 Makefile DEPENDS 保证。

. /usr/share/libubox/jshn.sh

# 确保运行/日志目录存在（flock 超时分支和 json_dump 都依赖目录，
# 独立运行或 /var 被清理后目录可能不存在）
mkdir -p /var/run/natmap /var/log/natmap

# ===========================================================================
# 并发锁分两把，各管各的
# ===========================================================================
# natmap 通过 fork 异步执行本脚本且不等待返回（src/hev-exec.c: fork 后父进程
# 直接 return，靠 SIGCHLD 收尸），多实例或映射连续变化时必然并发触发。要分开
# 解决的是两件性质完全不同的事：
#
#  ① /tmp/.natmap.lock —— 全局锁，只圈「状态 JSON + 端口转发」。
#     这一段会写 uci/firewall：fw4 的 reload 与 uci commit 都是整文件重写，
#     多实例并发写会互相覆盖，必须**跨实例串行**。
#  ② /tmp/.natmap-link.<实例>.lock —— 每实例锁，只圈「联动 + 自定义脚本」。
#     这两段只调远端 API / 跑用户脚本，一个本地共享状态都不写，不需要跨实例
#     串行；但必须保证**同一实例**的更新按序落地。
#
# 为什么必须分成两把：以前两段共用同一把锁，而锁的等待上限只有 30 秒，超时就
# **整段跳过**（转发与联动一起丢）。可联动的重试循环本身就要跑数十秒，于是
# 「一个实例的慢联动把别的实例饿死」—— 而打洞成功的映射变化事件不会重放，
# 被跳过的端口就永久停在旧值上。
# 实机事故（2026-10-02 17:09，luci-app-natmap 40.0.1-r1）：
#   nas_web 的 Cloudflare 联动登录失败重试两次（各 sleep 5 秒），
#   17:09:07 拿到锁、17:09:45 才放开，持锁 38 秒；同一窗口里 qBittorrent 的
#   更新 17:09:11 开始等锁，30 秒没等到被跳过 —— 它的监听端口与防火墙 DNAT
#   至今仍是 9-30 的旧值，而 Telegram 通知已经按新端口发出去了。
#
# 注意：BusyBox 的 flock 不支持 -w(等待超时)选项，只支持 [-sxun]，
# 所以 ① 用 -n 非阻塞 + 循环重试实现最长 30 秒的等待（若上一个实例异常卡住，
# 等 30 秒后放弃本次转发，避免被永久阻塞）；② 用阻塞式 -x（见下方注释）。
# 另：通知两把锁都不占（见文件末尾）—— 打洞成功事件不会重发，
# 通知被跳过就等于永久丢失。
exec 9>/tmp/.natmap.lock
locked=0
i=0
while [ "$i" -lt 30 ]; do
	if flock -n 9 2>/dev/null; then
		locked=1
		break
	fi
	sleep 1
	i=$((i + 1))
done

if [ "$locked" = 1 ]; then
	(
		json_init
		json_add_string ip "$1"
		json_add_int port "$2"
		json_add_string ip4p "$3"
		json_add_int inner_port "$4"
		json_add_string protocol "$5"
		json_add_string name "$GENERAL_NAT_NAME"
		json_dump >/var/run/natmap/$PPID.json
	)

	# 设置日志参数
	log_size_limit=1024000
	log_file="/var/log/natmap/natmap.log"

	# natmap logs setting
	# 日志大小限制超过1M则删除最早的日志，若日志不存在则创建日志文件
	if [ -f "/var/log/natmap/natmap.log" ]; then
		[ "$(wc -c /var/log/natmap/natmap.log | awk '{print $1}')" -gt "${log_size_limit}" ] && {
			[ -f "/var/log/natmap/natmap.log.1" ] && {
				rm -f /var/log/natmap/natmap.log.1
			}
			mv /var/log/natmap/natmap.log /var/log/natmap/natmap.log.1
		}
	else
		[ ! -d "/var/log/natmap" ] && {
			mkdir -p /var/log/natmap
		}
		touch /var/log/natmap/natmap.log
	fi

	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 开始更新" >>/var/log/natmap/natmap.log
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 开始更新"
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : natmap update json: $(cat /var/run/natmap/$PPID.json)" >>/var/log/natmap/natmap.log
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : natmap update json: $(cat /var/run/natmap/$PPID.json)"

	# forward setting
	#
	# FORWARD_ENABLE=0 时**不能直接跳过**：总开关刚被关掉，上一次写进防火墙的段
	# 还留在 uci 与内核里，而**只有插件知道该删哪些段名**。跳过的话那条 DNAT /
	# ACCEPT 会一直生效 —— 用户以为已经关了，外部其实还能打进来。
	#
	# 但也不能无条件调用：出厂配置就是 forward_enable=0 + forward_mode=firewall，
	# 无条件调用会让每个不用转发功能的用户每次打洞都多跑一次插件、多一条无意义的
	# 日志。所以先用段名探一下"防火墙里还有没有本实例的段"（段名算法与插件一致），
	# 有才把插件叫起来做清理。
	if [ "${FORWARD_ENABLE}" == 1 ]; then
		source /usr/share/natmap/forward.sh "$@"
	else
		_retire_v4=$(echo "${GENERAL_NAT_NAME}_v4" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}')
		_retire_v6=$(echo "${GENERAL_NAT_NAME}_v6_allow" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}')
		if [ -n "$(uci -q get firewall.$_retire_v4 2>/dev/null)" ] ||
			[ -n "$(uci -q get firewall.$_retire_v6 2>/dev/null)" ]; then
			source /usr/share/natmap/forward.sh "$@"
		fi
	fi

	# 全局锁的使命到此为止：状态 JSON 与 uci/防火墙都已经写完。
	# 后面的联动 / 自定义脚本 / 通知都不写本地共享状态，没有理由继续占着它 ——
	# 占着的每一秒都在让别的实例等锁，而它们等不到就会整段跳过（丢的是新端口）。
	exec 9>&-
else
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} - 上一次更新未结束(锁等待超时), 已跳过状态与端口转发更新 (联动与通知仍会执行)" >>/var/log/natmap/natmap.log
fi

# ===========================================================================
# 联动 + 自定义脚本（每实例锁，不占上面那把 uci 全局锁）
# ===========================================================================
# 为什么不用全局锁：这两段不写任何本地共享状态，却可能跑很久（联动自带 10 次 ×
# 5 秒的重试窗口，每次请求还有自己的超时）—— 放进全局锁正是上面那起实机事故的成因。
# 为什么还要单独加一把：同一实例连续两次映射变化时，后一次必须是最后落地的那个，
# 否则先发的慢请求后返回，会把端口写回旧值。这里用**阻塞式** flock 是刻意的：
# 等不到就跳过等于把新端口丢掉，而持有者是同一实例的上一个自己，它的时长由重试
# 上限与每次请求的超时兜住，不会无限期占着。
_link_lock="/tmp/.natmap-link.$(echo "${GENERAL_NAT_NAME:-natmap}" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}').lock"
exec 8>"$_link_lock"
flock -x 8 2>/dev/null

# link setting
[ "${LINK_ENABLE}" == 1 ] && source /usr/share/natmap/link.sh "$@"

# custom setting
# 路径是否存在在这里判断 —— init.d 侧不再用 file 类型硬校验：那会让一个「可选、
# 而且可能根本没启用」的功能把整个实例拖成"配置校验失败 → 不启动"。
# 注意：自定义脚本现在在每实例锁内、但**不在** uci 全局锁内 —— 脚本里若自己做
# uci set/commit，请自行保证不与别的实例的端口转发写入撞车。
[ "${CUSTOM_SCRIPT_ENABLE}" == 1 ] && [ -n "${CUSTOM_SCRIPT_PATH}" ] && {
	if [ -r "${CUSTOM_SCRIPT_PATH}" ]; then
		# 注意：不能用 bash 的 `export -n`（busybox ash 不支持，会在 OpenWrt 上报错）
		source "${CUSTOM_SCRIPT_PATH}" "$@"
	else
		echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 自定义脚本不存在或不可读, 已跳过: ${CUSTOM_SCRIPT_PATH}" >>/var/log/natmap/natmap.log
		echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 自定义脚本不存在或不可读, 已跳过: ${CUSTOM_SCRIPT_PATH}"
	fi
}

exec 8>&-

# notify setting
# 通知必须放在所有锁之外：打洞成功的映射变化事件不会被重放，
# 通知一旦被跳过就永久丢失（否则「3 次打洞只收到 2 条」）。
[ "${NOTIFY_ENABLE}" == 1 ] && source /usr/share/natmap/notify.sh "$@"
