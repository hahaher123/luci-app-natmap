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
# ②的放行范围是 **WAN zone → 目标 zone 的整个转发方向，端口为本次打洞端口，
# 协议同时放行 TCP 与 UDP**，规则带 family=ipv6。也就是说这条规则不针对任何
# IPv6 网段或单机地址：
#
#   * 公网 IPv6 没有 NAT，下载器监听的端口就是打洞拿到的 outter_port，
#     只需保证「外部能进来」，不需要 DNAT，也不需要写 dest_ip。
#   * 设备的 IPv6 后缀通常是随机隐私地址（SLAAC privacy extensions），
#     按单机地址放行隔天就失效；不写地址、只按端口放行才稳定。
#   * 同时放行 TCP 与 UDP：下载器通常两者（BT 的 uTP 走 UDP）都在用。
#
# 接口的 IPv6 前缀变化（运营商重新下发 PD）与 WAN 重拨不需要额外处理 ——
# 规则里根本没有网段。WAN 侧设备重建时 procd 会重启实例并重新打洞，届时端口
# 变化会把规则的 dest_port 一并刷新。
#
# 注意：本脚本所有日志都用 _log()（写文件 + stderr），不要用 stdout ——
# 插件的 stdout 被 forward.sh 透传给 procd。
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
# 所以这里统一把「网络名或 zone 名」规范化成真实 zone 名，解析不出来时退回原值，
# 保持老行为。
#
#   resolve_zone <网络名|zone名>
#     → 成功：RESOLVED_ZONE
# ================================================================
RESOLVED_ZONE=""
_WANT=""

_zone_scan() {
	local section="$1" zname nets n

	config_get zname "$section" name
	[ -n "$zname" ] || return 0

	# ① 填进去的本身就是 zone 名
	if [ "$zname" = "$_WANT" ]; then
		RESOLVED_ZONE="$zname"
		return 0
	fi

	# 已经有匹配了就不再覆盖
	[ -n "$RESOLVED_ZONE" ] && return 0

	# ② 该 zone 的 network 列表里含这个网络名
	config_get nets "$section" network
	for n in $nets; do
		if [ "$n" = "$_WANT" ]; then
			RESOLVED_ZONE="$zname"
			return 0
		fi
	done
	return 0
}

resolve_zone() {
	RESOLVED_ZONE=""
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
if resolve_zone "$FORWARD_FIREWALL_TARGET_INTERFACE"; then
	dest_zone="$RESOLVED_ZONE"
fi

# 目标接口为空时回退到 lan zone。
#
# forward_firewall_target_interface 是「端口转发」页给 **IPv4 DNAT** 用的选项，
# 很多只做 IPv6 放行的用户根本不会去填它。而 IPv6 放行的目标天然就是内网（LAN），
# 早期版本在这里直接判空跳过，导致这类用户永远建不出放行规则，日志还只说
# 「未配置 WAN 或转发目标接口」—— 看不出该去填哪个框。
#
# 注意报文的 src 侧不做同样回退：WAN 是IPv6 流量的入口，猜错方向会放行错东西，
# 宁可跳过（v4 的 src 仍取页面配置，行为不变）。
if [ -z "$dest_zone" ]; then
	dest_zone="lan"
	if resolve_zone "lan"; then
		dest_zone="$RESOLVED_ZONE"
	fi
	_log "未配置转发目标接口, IPv6 放行目标回退为 $dest_zone"
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

	if [ -z "$src_zone" ]; then
		_log "未配置 WAN 接口, 无法确定放行来源, 跳过 IPv6 放行 (请在基本设置里选择 WAN 接口)"
	else
		rule_name_v6=$(echo "${GENERAL_NAT_NAME}_v6_allow" | sed 's/[^a-zA-Z0-9]/_/g' | awk '{print tolower($0)}')
		_log "firewall_rule_name_v6: $rule_name_v6 ($src_zone -> $dest_zone), 放行 ipv6 tcp+udp 端口 $outter_port"

		uci set firewall.$rule_name_v6=rule
		uci set firewall.$rule_name_v6.name=$rule_name_v6
		uci set firewall.$rule_name_v6.src=$src_zone
		uci set firewall.$rule_name_v6.dest=$dest_zone
		uci set firewall.$rule_name_v6.target=ACCEPT
		# 同时放行 TCP 与 UDP：BT 的 uTP 走 UDP，只放 TCP 会留下半个缺口
		uci set firewall.$rule_name_v6.proto="tcp udp"
		uci set firewall.$rule_name_v6.family=ipv6
		# IPv6 无 NAT，qBittorrent/Transmission 监听端口即打洞获得的外部端口
		# ($outter_port)，不能使用 forward_target_port（那是 IPv4 DNAT 的目标
		# 端口，与下载器监听端口无关）
		uci set firewall.$rule_name_v6.dest_port=$outter_port

		# 早期版本会写入 dest_ip（自动探测 LAN 网段）。换成按端口放行后不再需要
		# 任何地址限制 —— 但残留的 dest_ip 会把规则重新窄化成"只放行旧网段"，
		# 旧网段一旦失效规则就等于没生效，所以每次都要清掉。
		uci -q delete firewall.$rule_name_v6.dest_ip 2>/dev/null
	fi
fi

# ================================================================
# 应用规则：reload 带重试 → restart 兜底 → 内核侧核对
# ================================================================
#
# ① 为什么 reload 要重试：fw4 的 reload 有一个**瞬时失败窗口**。
#    root/sbin/fw4 的骨架是
#
#        start()   { { flock -x 1000; ...; } 1000>$LOCK }
#        restart)  QUIET=1 print | nft -c -f - || die ...; stop || rm -f $STATE; start ;;
#
#    restart 的 stop 与 start 之间：$STATE 已被删除，而 flock 是**空着的**。
#    此刻另一路 fw4 reload 拿到锁 → [ ! -f $STATE ] → 立刻 die（瞬时 exit 1，不是
#    超时；实机日志里它和上一条日志同秒，正是这个特征）。
#    撞车源头很常见 —— interface hotplug（root/etc/hotplug.d/iface/20-firewall 里
#    就是 `fw4 -q reload`，与插件同锁同路）以及 LuCI 防火墙页的「保存并应用」
#    （走 restart）；而 natmap 打洞本身就是 WAN 事件驱动的，两者天然会同时发生。
#    这类失败重试一两次就好；不重试就只能靠 restart 兜底（代价是整个规则集重建）。
#
# ② 为什么还要 restart 兜底：$STATE 真丢了（/var 被清理、启动没走到写状态那一步）
#    时 reload 会**每次都** die，只有 restart 能重建状态文件。
#
# ③ 为什么成功之后还要核对内核：**fw4 reload 的退出码不可信**。
#    start() 里那个块的退出码取**块内最后一条命令**：
#
#        ACTION=start    utpl -S $MAIN | nft $VERBOSE -f $STDIN   # 失败会被下面覆盖
#        ACTION=includes utpl -S $MAIN                            # ← 退出码看这条
#
#    所以 nft 加载失败时 reload 照样返回 0：规则没进内核，调用方却以为成功。
#    fw4 给每条渲染出来的规则都打了 comment "!fw4: <段名>"
#    （templates/rule.uc、templates/redirect.uc），拿它到**内核当前规则集**里反查，
#    才算真正证明"生效"。核对失败时日志会直说"请执行 /etc/init.d/firewall restart"。
#
# 另外把命令**自己的输出**一并记下来：以前这里只记「超时或失败」，命令打印的原因
# （fw4 的 die 信息、nft 的报错）被丢掉，导致谁都看不出为什么失败。
FW_RELOAD_TRIES=3
FW_RELOAD_WAIT=2

# 跑一条命令：合并 stdout/stderr 到 FW_OUT，返回它自己的退出码
_fw_try() {
	local t="$1" out rc
	shift
	if command -v timeout >/dev/null 2>&1; then
		out=$(timeout "$t" "$@" 2>&1)
		rc=$?
	else
		out=$("$@" 2>&1)
		rc=$?
	fi
	FW_OUT="$out"
	return "$rc"
}

# 把命令输出压成一两行记进日志 —— fw4 的 die 原因就在这里面
_fw_log_out() {
	[ -n "$FW_OUT" ] || return 0
	_log "$1$(printf '%s' "$FW_OUT" | tail -n 2 | tr '\n' ' ')"
}

# 到内核当前规则集里反查 fw4 打的规则标记
#   $@ = 要核对的段名
#   返回 0=全部命中；1=有未命中（名字留在 FW_VERIFY_MISS）；2=无法核对（没有 fw4/nft）
_fw_verify_kernel() {
	local name miss="" rules
	command -v fw4 >/dev/null 2>&1 || return 2
	command -v nft >/dev/null 2>&1 || return 2
	rules=$(nft list ruleset 2>/dev/null) || return 2
	for name in "$@"; do
		[ -n "$name" ] || continue
		case "$rules" in
		*"!fw4: $name"*) ;;
		*) miss="$miss $name" ;;
		esac
	done
	[ -n "$miss" ] || return 0
	FW_VERIFY_MISS="$miss"
	return 1
}

# 核对并说清结果（失败时给出可执行的那一步）
_fw_verify() {
	local names="$*"
	[ -n "$(printf '%s' "$names" | tr -d ' ')" ] || return 0
	_fw_verify_kernel "$@"
	case "$?" in
	0) _log "内核侧核对通过:${names} 已在内核生效" ;;
	1) _log "内核侧核对未通过: 内核里找不到${FW_VERIFY_MISS} —— 命令返回成功不等于规则进了内核, 请执行 /etc/init.d/firewall restart 复核" ;;
	*) _log "内核侧核对跳过: 没有 fw4 或 nft (fw3 / 裁剪固件), 无法反查规则标记" ;;
	esac
	return 0
}

_fw_apply() {
	local i rc

	i=1
	while [ "$i" -le "$FW_RELOAD_TRIES" ]; do
		_fw_try 60 /etc/init.d/firewall reload
		rc=$?
		if [ "$rc" = 0 ]; then
			_log "firewall reload 成功 (第 $i 次尝试)"
			_fw_verify "$@"
			return 0
		fi
		_log "firewall reload 第 $i/$FW_RELOAD_TRIES 次失败(rc=$rc)"
		_fw_log_out "firewall reload 输出: "
		[ "$i" -lt "$FW_RELOAD_TRIES" ] && sleep "$FW_RELOAD_WAIT"
		i=$((i + 1))
	done

	_log "firewall reload 连续 $FW_RELOAD_TRIES 次失败, 改用 restart 重建规则集"
	_fw_try 120 /etc/init.d/firewall restart
	rc=$?
	if [ "$rc" = 0 ]; then
		_log "firewall restart 成功, 规则已生效"
		_fw_verify "$@"
		return 0
	fi

	_fw_log_out "firewall restart 输出: "
	if [ "$rc" = 124 ]; then
		_log "firewall restart 超时(120 秒未结束) — 请手动执行 /etc/init.d/firewall restart"
	else
		_log "firewall restart 失败(rc=$rc) — 请手动执行 /etc/init.d/firewall restart"
	fi
	return 1
}

# 只核对我们这次真正写过的规则（没写的段名不该出现在内核里）
VERIFY_RULE_NAMES=""
[ "$do_v4" = 1 ] && VERIFY_RULE_NAMES="$rule_name_v4"
if [ "$do_v6" = 1 ] && [ -n "${rule_name_v6:-}" ]; then
	VERIFY_RULE_NAMES="$VERIFY_RULE_NAMES $rule_name_v6"
fi

uci commit firewall
# 故意不加引号：VERIFY_RULE_NAMES 是空格分隔的多个段名
_fw_apply $VERIFY_RULE_NAMES
