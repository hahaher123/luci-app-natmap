#!/bin/bash
# natmap 实例启动包装脚本
#
# 由 init.d 作为 procd 的 command 执行：
#   wait-network.sh <natmap 可执行文件> <natmap 参数...>
#
# 背景：natmap 上游核心没有"等待网络"的能力，STUN 连不通就直接退出。
# 开机或网络重置时若 WAN 尚未就绪，natmap 会连续快速失败，耗尽 procd 的
# respawn 次数后实例彻底停摆；另外 init.d 声明实例时网络可能还没起来，
# 那时解析 WAN 设备名会失败并回落到逻辑接口名（如 wan），-i 参数非法。
#
# 本脚本做两件事：
#   1. 启动前等待网络就绪（WAN 接口 up / 设备存在 / STUN 服务器可达）；
#   2. 就绪后再解析 WAN 设备名，用 -i 传给 natmap。
#
# 关键设计（保证不影响网络重置后重新打洞）：
#   * 等待有上限（GENERAL_WAIT_NETWORK_TIMEOUT 秒），超时后**照常启动** natmap。
#     探测只用来"尽量晚启动"，绝不阻塞打洞：探测误判（如 ICMP 被上游屏蔽）
#     最多让本次启动晚一点，不会导致 natmap 不启动。
#   * 最终 exec 到 natmap，不引入额外常驻进程（PID 不变，procd 的
#     respawn / netdev / stop 全部直接作用于 natmap）。
#   * 网络重置时 WAN 设备重建 → procd 检测到 netdev ifindex 变化 → 重启实例
#     → 本脚本重新等待就绪 → natmap 重新打洞，链路与改造前一致。

. /lib/functions/network.sh 2>/dev/null

LOG_FILE=/var/log/natmap/natmap.log

mkdir -p /var/run/natmap /var/log/natmap 2>/dev/null

# 收到 procd 的停止信号立即退出：sleep 放后台 + wait，
# 否则 bash 要等 sleep 结束才处理信号，停止动作最多被拖慢一个轮询周期
trap 'exit 143' TERM INT

log() {
	echo "$(date +'%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} - $*" >>"${LOG_FILE}" 2>/dev/null
}

# 解析 WAN 逻辑接口对应的网络设备名（成功则输出设备名）
resolve_device() {
	local iface="$1"
	local dev=""

	[ -n "$iface" ] || return 1

	# 优先取 ubus 的 l3_device：PPPoE 等场景下它才是真正承载地址的设备
	if command -v ubus >/dev/null 2>&1; then
		dev="$(ubus -S -t 3 call "network.interface.${iface}" status 2>/dev/null |
			jq -r '.l3_device // .device // empty' 2>/dev/null)"
	fi

	# 回落到 /lib/functions/network.sh 提供的方法
	if [ -z "${dev}" ] || [ ! -e "/sys/class/net/${dev}" ]; then
		dev=""
		network_get_device dev "${iface}" 2>/dev/null
	fi

	[ -n "${dev}" ] && [ -e "/sys/class/net/${dev}" ] || return 1

	printf '%s' "${dev}"
}

# 逻辑接口是否已 up；拿不到状态（ubus 不可用/接口未注册）时不做判断
iface_is_up() {
	local iface="$1"
	local up=""

	command -v ubus >/dev/null 2>&1 || return 0

	up="$(ubus -S -t 3 call "network.interface.${iface}" status 2>/dev/null |
		jq -r '.up // empty' 2>/dev/null)"

	case "${up}" in
	"true") return 0 ;;
	"") return 0 ;;
	*) return 1 ;;
	esac
}

# STUN 服务器是否可解析/可达（剥掉 [v6] 与端口）
stun_reachable() {
	local host="$1"
	local have_tool=0

	[ -n "${host}" ] || return 0

	case "${host}" in
	\[*\]*) host="${host%:*}" ;;
	*:*:*) : ;;
	*:*) host="${host%:*}" ;;
	esac
	host="${host#\[}"
	host="${host%\]}"

	[ -n "${host}" ] || return 0

	if command -v ping >/dev/null 2>&1; then
		have_tool=1
		ping -c 1 -W 2 "${host}" >/dev/null 2>&1 && return 0
	fi

	# ICMP 可能被上游屏蔽，用 DNS 解析作为补充信号（限时，避免解析卡住）
	if command -v nslookup >/dev/null 2>&1; then
		have_tool=1
		timeout 3 nslookup "${host}" >/dev/null 2>&1 && return 0
	fi

	# 没有任何可用探测工具：视为"未知"，不阻塞启动
	[ "${have_tool}" = 1 ] || return 0

	return 1
}

# 网络是否就绪：接口 up + 设备存在 + STUN 可达
network_ready() {
	if [ -n "${GENERAL_WAN_INTERFACE}" ]; then
		iface_is_up "${GENERAL_WAN_INTERFACE}" || return 1
		resolve_device "${GENERAL_WAN_INTERFACE}" >/dev/null || return 1
	fi

	stun_reachable "${GENERAL_STUN_SERVER}" || return 1

	return 0
}

[ -n "$1" ] || {
	log "启动失败: 未指定 natmap 可执行文件"
	exit 1
}
natmap_bin="$1"
shift

# general_wait_network 为空（老配置升级上来的情况）视为启用，显式关闭才跳过等待
wait_timeout="${GENERAL_WAIT_NETWORK_TIMEOUT:-120}"
case "${wait_timeout}" in
'' | *[!0-9]*) wait_timeout=120 ;;
esac
case "$(printf '%s' "${GENERAL_WAIT_NETWORK}" | tr 'A-Z' 'a-z')" in
0 | false | off | no | disabled) wait_timeout=0 ;;
esac

if [ "${wait_timeout}" -gt 0 ]; then
	# 用真实时间判断超时：探测本身（ping/DNS）也要花时间，
	# 按轮询次数计时会让实际等待明显长于配置值
	start_ts="$(date +%s)"
	deadline=$((start_ts + wait_timeout))
	first=1
	slept=0

	while :; do
		if network_ready; then
			if [ "${slept}" = 1 ]; then
				log "网络已就绪(等待 $(($(date +%s) - start_ts)) 秒), 开始打洞"
			fi
			break
		fi

		now="$(date +%s)"
		if [ "${now}" -ge "${deadline}" ]; then
			log "等待网络就绪超时(${wait_timeout} 秒), 照常启动 natmap"
			break
		fi

		[ "${first}" = 1 ] && log "等待网络就绪(最长 ${wait_timeout} 秒)..."
		first=0

		sleep 2 &
		wait $!
		slept=1
	done
fi

# 网络就绪后再解析设备名：init.d 声明实例时网络可能还没起来
args=()
if [ -n "${GENERAL_WAN_INTERFACE}" ]; then
	dev="$(resolve_device "${GENERAL_WAN_INTERFACE}")" || {
		dev=""
		log "无法解析 WAN 接口 ${GENERAL_WAN_INTERFACE} 的设备名, 本次不指定 -i"
	}
	[ -n "${dev}" ] && args+=(-i "${dev}")
fi

exec "${natmap_bin}" "${args[@]}" "$@"
