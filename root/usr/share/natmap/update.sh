#!/bin/bash
# 注意：本脚本由 natmap 按文件 shebang 直接执行，且会 source
# forward/link/notify 等 bash 脚本，必须保持 #!/bin/bash；
# bash 依赖由 natmap/luci-app-natmap 的 Makefile DEPENDS 保证。

. /usr/share/libubox/jshn.sh

# 确保运行/日志目录存在（flock 超时分支和 json_dump 都依赖目录，
# 独立运行或 /var 被清理后目录可能不存在）
mkdir -p /var/run/natmap /var/log/natmap

# 并发锁：natmap 通过 fork 异步执行本脚本且不等待返回，
# 多实例或映射连续变化时可能并发触发，这里串行化避免并发写 uci/防火墙。
# 注意：BusyBox 的 flock 不支持 -w(等待超时)选项，只支持 [-sxun]，
# 因此用 -n 非阻塞加锁 + 循环重试实现最长 30 秒的等待：
# 若上一个实例异常卡住，等待 30 秒后跳过本次更新，
# 避免整条链路(状态JSON/转发/通知)被永久阻塞
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
[ "$locked" = 1 ] || {
	echo "$(date +'%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} - 上一次更新未结束(锁等待超时), 跳过本次" >>/var/log/natmap/natmap.log
	exit 1
}

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

echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 开始更新" >>/var/log/natmap/natmap.log
echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - 开始更新"
echo "$(date +'%Y-%m-%d %H:%M:%S') : natmap update json: $(cat /var/run/natmap/$PPID.json)" >>/var/log/natmap/natmap.log
echo "$(date +'%Y-%m-%d %H:%M:%S') : natmap update json: $(cat /var/run/natmap/$PPID.json)"

# forward setting
[ "${FORWARD_ENABLE}" == 1 ] && source /usr/share/natmap/forward.sh "$@"

# link setting
[ "${LINK_ENABLE}" == 1 ] && source /usr/share/natmap/link.sh "$@"

# custom setting
[ "${CUSTOM_SCRIPT_ENABLE}" == 1 ] && [ -n "${CUSTOM_SCRIPT_PATH}" ] && {
	# 注意：不能用 bash 的 `export -n`（busybox ash 不支持，会在 OpenWrt 上报错）
	source "${CUSTOM_SCRIPT_PATH}" "$@"
}

# notify setting
[ "${NOTIFY_ENABLE}" == 1 ] && source /usr/share/natmap/notify.sh "$@"
