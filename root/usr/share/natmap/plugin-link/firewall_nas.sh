#!/bin/bash
# ============================================================
# NATMap 附加脚本：将打洞端口同步到防火墙 nas_incoming_5 规则
#   $1 = outter_ip     打洞后的公网 IP
#   $2 = outter_port   打洞后的外部端口（要同步到防火墙的端口）
#   $3 = ip4p
#   $4 = inner_port    内网端口
#   $5 = protocol      tcp / udp
# ============================================================
RULE_NAME="nas_incoming_5"
RULE_DEST_IP=""
SYNC_PROTO="1"
outter_ip=$1
outter_port=$2
ip4p=$3
inner_port=$4
protocol=$5
LOG_FILE="/var/log/natmap/natmap.log"
log() {
	[ -d "/var/log/natmap" ] || mkdir -p "/var/log/natmap"
	echo "$(date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} : firewall-$RULE_NAME : $*" >>"$LOG_FILE"
	echo "$(date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-natmap} : firewall-$RULE_NAME : $*"
}
main() {
	case "$outter_port" in
		''|*[!0-9]*)
			log "无效的外部端口: '$outter_port', 跳过"
			return 1
			;;
	esac
	if [ "$outter_port" -lt 1 ] || [ "$outter_port" -gt 65535 ]; then
		log "外部端口越界: $outter_port, 跳过"
		return 1
	fi
	RULE_SECTION=""
	if uci show firewall 2>/dev/null | grep -q "^firewall\.${RULE_NAME}=rule$"; then
		RULE_SECTION="firewall.${RULE_NAME}"
	else
		RULE_SECTION=$(uci show firewall 2>/dev/null | sed -n "s/^\(firewall\.@rule\[[0-9]*\]\)\.name='${RULE_NAME}'$/\1/p" | head -n1)
	fi
	if [ -z "$RULE_SECTION" ]; then
		log "未找到防火墙规则 '${RULE_NAME}', 跳过"
		return 1
	fi
	log "开始更新规则 ${RULE_SECTION}: 端口 -> $outter_port (协议 $protocol, 外部IP $outter_ip)"
	CHANGED=0
	if [ "$(uci get "${RULE_SECTION}.dest_port" 2>/dev/null)" != "$outter_port" ]; then
		uci set "${RULE_SECTION}.dest_port=$outter_port"
		CHANGED=1
	fi
	if [ -n "$RULE_DEST_IP" ] && [ "$(uci get "${RULE_SECTION}.dest_ip" 2>/dev/null)" != "$RULE_DEST_IP" ]; then
		uci set "${RULE_SECTION}.dest_ip=$RULE_DEST_IP"
		CHANGED=1
	fi
	if [ "$SYNC_PROTO" = "1" ] && [ -n "$protocol" ]; then
		CUR_PROTO=$(uci get "${RULE_SECTION}.proto" 2>/dev/null)
		case " $CUR_PROTO " in
			*" $protocol "*)
				: ;;
			*)
				if [ -z "$CUR_PROTO" ]; then
					uci set "${RULE_SECTION}.proto=$protocol"
				else
					uci set "${RULE_SECTION}.proto=$CUR_PROTO $protocol"
				fi
				CHANGED=1
				;;
		esac
	fi
	if [ -z "$(uci get "${RULE_SECTION}.target" 2>/dev/null)" ]; then
		uci set "${RULE_SECTION}.target=ACCEPT"
		CHANGED=1
	fi
	if [ "$CHANGED" = "0" ]; then
		log "端口/协议未变化, 无需 reload"
		return 0
	fi
	uci commit firewall
	if /etc/init.d/firewall reload >/dev/null 2>&1; then
		log "已完成: ${RULE_SECTION}.dest_port = $outter_port, 防火墙已 reload"
	else
		log "防火墙 reload 失败, 请手动执行 /etc/init.d/firewall reload"
		return 1
	fi
	return 0
}
main "$@"
