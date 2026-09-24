#!/bin/bash
# ============================================================
# NATMap 转发插件：防火墙（fw4 / fw3）
#   $1 = outter_ip     打洞后的公网 IP
#   $2 = outter_port   打洞后的外部端口
#   $3 = ip4p
#   $4 = inner_port    内网端口
#   $5 = protocol      tcp / udp
#
# 这里做两件**互相独立**的事（早先两件事被同一个前置判断捆在一起，只想要 IPv6
# 放行的用户在没配 IPv4 转发目标时会被直接跳过）：
#
#   ① IPv4 端口转发（DNAT）—— 需要 FORWARD_TARGET_IP / FORWARD_TARGET_PORT
#   ② qBittorrent / Transmission 的 IPv6 放行 —— 需要 LINK_ENABLE=1 且
#      LINK_MODE 对应的 LINK_QB_ALLOW_IPV6 / LINK_TR_ALLOW_IPV6=1
#
# ②的放行目标是**自动探测出来的 LAN IPv6 段**：公网 IPv6 没有 NAT，下载器监听端口
# 就是打洞拿到的 outter_port，所以只需要「外部能进来」；而设备的 IPv6 后缀常是随机
# 的隐私地址（SLAAC privacy extensions），按单机地址放行隔天就失效 —— 放行整个
# LAN 段才稳定，设备换地址也不用管。多 LAN（同一防火墙 zone 的 list network 里有
# 多个接口）全部覆盖。需要额外放行固定地址或别的网段时，用页面上的
# 「Extra IPv6 Address」补充（可留空）。
#
# 注意：本脚本所有日志都用 _log()（写文件 + stderr），不要用 stdout ——
# 插件的 stdout 被 forward.sh 透传给 procd，探测函数的 stdout 还要当数据用。
# ============================================================
outter_ip=$1
outter_port=$2
ip4p=$3
inner_port=$4
protocol=$5

LOG_FILE="/var/log/natmap/natmap.log"

_log() {
	[ -d "/var/log/natmap" ] || mkdir -p "/var/log/natmap"
	echo "$(TZ='CST-8' date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} : firewall-forward : $*" >>"$LOG_FILE"
	echo "$(TZ='CST-8' date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} : firewall-forward : $*" >&2
}

# ================================================================
# 网络名 → 防火墙 zone
#
# 页面上 general_wan_interface / forward_firewall_target_interface 都是
# NetworkSelect，填进去的是 /etc/config/network 里的**网络名**；而 fw4 解析规则的
# src / dest 时只按 zone.name 匹配（fw4.uc parse_zone_ref：`if (zone.name == val)`），
# 不认识网络名。传统 lan / wan 恰好网络名与 zone 名同名才侥幸生效，一旦用户把目标
# 接口选成 lan2 之类，规则其实落不到任何 zone 上。
#
# 所以这里统一把「网络名或 zone 名」规范化成真实 zone 名，并顺手取出该 zone 的
# 全部 network —— 多 LAN 就是靠这个覆盖的。解析不出来时退回原值，保持老行为。
#
#   resolve_zone <网络名|zone名>
#     → 成功：RESOLVED_ZONE / RESOLVED_NETWORKS
# ================================================================
RESOLVED_ZONE=""
RESOLVED_NETWORKS=""
_WANT=""

_zone_scan() {
	local section="$1" zname nets n

	config_get zname "$section" name
	[ -n "$zname" ] || return 0

	# ① 填进去的本身就是 zone 名
	if [ "$zname" = "$_WANT" ]; then
		RESOLVED_ZONE="$zname"
		config_get RESOLVED_NETWORKS "$section" network
		return 0
	fi

	# 已经有匹配了就不再覆盖
	[ -n "$RESOLVED_ZONE" ] && return 0

	# ② 该 zone 的 network 列表里含这个网络名
	config_get nets "$section" network
	for n in $nets; do
		if [ "$n" = "$_WANT" ]; then
			RESOLVED_ZONE="$zname"
			RESOLVED_NETWORKS="$nets"
			return 0
		fi
	done
	return 0
}

resolve_zone() {
	RESOLVED_ZONE=""
	RESOLVED_NETWORKS=""
	_WANT="$1"
	[ -n "$_WANT" ] || return 1

	# /lib/functions.sh 提供 config_load / config_get / config_foreach
	[ -r /lib/functions.sh ] && . /lib/functions.sh
	if ! type config_load >/dev/null 2>&1 || ! type config_foreach >/dev/null 2>&1; then
		return 1
	fi

	config_load firewall 2>/dev/null || return 1
	config_foreach _zone_scan zone

	[ -n "$RESOLVED_ZONE" ]
}

# ================================================================
# LAN IPv6 段探测
#
# 两个来源，都保证是**规范化前缀**（地址即网段基址，主机位为 0）：
#   ① ip -6 route show dev <dev>：内核 main 表里每个已配置前缀都有一条
#      `<prefix>/<len> dev <dev> proto kernel`，天然规范化，PD 分配与静态配置
#      都覆盖。默认只显示 main 表，所以不会把 table local 里的 /128 主机路由混进来。
#   ② ubus status 的 ipv6-prefix-assignment：netifd 记录的前缀分配
#      （.address 是网段基址、.mask 是长度），①取不到时兜底。
#
# 过滤掉链路本地 fe80::/10 与多播 ff00::/8 —— 这两类不能当放行目标。
# ================================================================
net_device() {
	ubus call network.interface."$1" status 2>/dev/null |
		jq -r '.l3_device // empty' 2>/dev/null | head -n1
}

prefix_from_route() {
	local line pfx lc
	ip -6 route show dev "$1" 2>/dev/null | while read -r line; do
		# 只取第一个字段（前缀），不依赖后续字段的顺序/是否存在（busybox ip
		# 与 iproute2 的列不完全一致）
		pfx=${line%% *}
		[ -n "$pfx" ] || continue
		case "$pfx" in
		*/*) ;;
		*) continue ;;
		esac
		lc=$(printf '%s' "$pfx" | tr 'A-Z' 'a-z')
		case "$lc" in
		fe8*|fe9*|fea*|feb*|ff*|::1/*|::/*) continue ;;
		esac
		printf '%s\n' "$pfx"
	done
}

prefix_from_ubus() {
	local json
	json=$(ubus call network.interface."$1" status 2>/dev/null) || return 0
	[ -n "$json" ] || return 0
	printf '%s' "$json" | jq -r '
		.["ipv6-prefix-assignment"][]?
		| select(.address != null and .mask != null)
		| "\(.address)/\(.mask)"' 2>/dev/null
}

# collect_lan_prefixes <网络名...>  → 结果写入全局 LAN_PREFIXES（空格分隔，去重）
# 用全局变量而不是管道：_log() 也会输出，管道会把它混进前缀列表。
LAN_PREFIXES=""
collect_lan_prefixes() {
	local net dev pfx found

	for net in "$@"; do
		[ -n "$net" ] || continue
		dev=$(net_device "$net")
		if [ -z "$dev" ]; then
			_log "接口 $net 没有 l3_device（未启用或不存在），跳过"
			continue
		fi
		found=""
		for pfx in $(prefix_from_route "$dev"); do
			found="$found $pfx"
		done
		if [ -z "$found" ]; then
			# 路由表里没有（极少数情况），退回 netifd 记录的前缀分配
			for pfx in $(prefix_from_ubus "$net"); do
				found="$found $pfx"
			done
		fi
		if [ -n "$found" ]; then
			_log "接口 $net (设备 $dev) IPv6 段:$found"
			LAN_PREFIXES="$LAN_PREFIXES $found"
		else
			_log "接口 $net (设备 $dev) 未取到 IPv6 段（该接口没有全局 IPv6 前缀？）"
		fi
	done
}

# ================================================================
# 判断这次要做哪些事
# ================================================================
do_v4=0
if [ -n "$FORWARD_TARGET_PORT" ] && [ -n "$FORWARD_TARGET_IP" ]; then
	do_v4=1
fi

do_v6=0
if [ "${LINK_ENABLE}" = 1 ]; then
	case "${LINK_MODE}" in
	qbittorrent)
		[ "${LINK_QB_ALLOW_IPV6}" = 1 ] && do_v6=1
		;;
	transmission)
		[ "${LINK_TR_ALLOW_IPV6}" = 1 ] && do_v6=1
		;;
	esac
fi

if [ "$do_v4" = 0 ] && [ "$do_v6" = 0 ]; then
	_log "无 IPv4 转发目标，也无 IPv6 放行需求, 跳过"
	exit 0
fi

# src / dest 两边都要用真实 zone 名，统一先解析
src_zone="$GENERAL_WAN_INTERFACE"
if resolve_zone "$GENERAL_WAN_INTERFACE"; then
	[ -n "$RESOLVED_ZONE" ] && src_zone="$RESOLVED_ZONE"
fi

dest_zone="$FORWARD_FIREWALL_TARGET_INTERFACE"
lan_networks="$FORWARD_FIREWALL_TARGET_INTERFACE"
if resolve_zone "$FORWARD_FIREWALL_TARGET_INTERFACE"; then
	dest_zone="$RESOLVED_ZONE"
	[ -n "$RESOLVED_NETWORKS" ] && lan_networks="$RESOLVED_NETWORKS"
fi

# ================================================================
# ① IPv4 端口转发（DNAT）
# ================================================================
if [ "$do_v4" = 1 ]; then
	final_forward_target_port=$((FORWARD_TARGET_PORT == 0 ? outter_port : FORWARD_TARGET_PORT))

	rule_name_v4=$(echo "${GENERAL_NAT_NAME}_v4" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}')
	_log "firewall_rule_name_v4: $rule_name_v4 (src zone: $src_zone)"

	uci set firewall.$rule_name_v4=redirect
	uci set firewall.$rule_name_v4.name=$rule_name_v4
	uci set firewall.$rule_name_v4.proto=$protocol
	uci set firewall.$rule_name_v4.src=$src_zone
	uci set firewall.$rule_name_v4.dest=$dest_zone
	uci set firewall.$rule_name_v4.target=DNAT
	uci set firewall.$rule_name_v4.src_dport=$inner_port
	uci set firewall.$rule_name_v4.dest_ip=$FORWARD_TARGET_IP
	uci set firewall.$rule_name_v4.dest_port=$final_forward_target_port
fi

# ================================================================
# ② qBittorrent / Transmission 的 IPv6 放行
# ================================================================
#
# 注意这里全部用「守卫式跳过」而不是 exit —— 上面的 IPv4 规则可能已经 uci set
# 过了，提前 exit 会让它永远等不到下面的 commit/reload，IPv4 转发就悄悄失效了。
#
if [ "$do_v6" = 1 ]; then

	if [ -z "$dest_zone" ]; then
		_log "未配置转发目标接口, 无法确定放行 zone, 跳过 IPv6 放行"
	else
		# 手动补充（可留空；页面 / init.d 的 datatype 都是
		# list(or(ip6addr,cidr6))，所以空格分隔的多个值都合法）
		case "${LINK_MODE}" in
		"transmission") manual="$LINK_TR_IPV6_ADDRESS" ;;
		"qbittorrent") manual="$LINK_QB_IPV6_ADDRESS" ;;
		*) manual="" ;;
		esac

		_log "IPv6 放行: zone=$dest_zone (网络:$lan_networks) 手动补充:[$manual]"

		LAN_PREFIXES=""
		collect_lan_prefixes $lan_networks

		for pfx in $manual; do
			# 历史配置里常见占位值 ::/-64（服务端校验现在会拦掉新输入，但老配置还在），
			# 这种不是合法前缀，直接丢掉而不是塞进 dest_ip 让 fw4 reload 失败
			case "$pfx" in
			::/*/*|*/-*) continue ;;
			*/*) ;;
			*) pfx="$pfx/128" ;;
			esac
			LAN_PREFIXES="$LAN_PREFIXES $pfx"
		done

		all_prefixes=$(printf '%s\n' $LAN_PREFIXES | grep -v '^$' | sort -u | tr '\n' ' ')
		all_prefixes=${all_prefixes% }

		if [ -z "$all_prefixes" ]; then
			# 探测失败不能退化成「没有 dest_ip 的规则」—— 那等于对整个 LAN 放行这个端口
			_log "未探测到任何 LAN IPv6 段, 且未手工填写, 跳过 IPv6 放行"
		else
			rule_name_v6=$(echo "${GENERAL_NAT_NAME}_v6_allow" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}')
			_log "firewall_rule_name_v6: $rule_name_v6 (zone: $src_zone -> $dest_zone), dest_ip:$all_prefixes"

			uci set firewall.$rule_name_v6=rule
			uci set firewall.$rule_name_v6.name=$rule_name_v6
			uci set firewall.$rule_name_v6.src=$src_zone
			uci set firewall.$rule_name_v6.dest=$dest_zone
			uci set firewall.$rule_name_v6.target=ACCEPT
			uci set firewall.$rule_name_v6.proto=$protocol
			uci set firewall.$rule_name_v6.family=ipv6
			# IPv6 无 NAT，qBittorrent/Transmission 监听端口即打洞获得的外部端口
			# ($outter_port)，不能使用 forward_target_port（那是 IPv4 DNAT 的目标
			# 端口，与下载器监听端口无关）
			uci set firewall.$rule_name_v6.dest_port=$outter_port

			# 每次重建 dest_ip 列表：IPv6 前缀会随 PD 变化，残留旧段等于白白多放行
			uci -q delete firewall.$rule_name_v6.dest_ip 2>/dev/null
			for pfx in $all_prefixes; do
				uci add_list firewall.$rule_name_v6.dest_ip=$pfx
			done
		fi
	fi
fi

# reload（加超时，防止防火墙卡住拖垮整个更新链路）
uci commit firewall
timeout 30 /etc/init.d/firewall reload ||
	_log "firewall reload 超时或失败, 请手动执行 /etc/init.d/firewall reload"
