#!/bin/bash
# NATMap
outter_ip=$1
outter_port=$2
ip4p=$3
inner_port=$4
protocol=$5

# 判断这次有没有活要干。
#
# 早先这里以「FORWARD_TARGET_PORT / FORWARD_TARGET_IP 为空就 exit」为唯一条件，
# 于是只想要 qBittorrent / Transmission 的 IPv6 放行（公网 IPv6 不需要端口转发）
# 的用户，插件根本不会被调用 —— 放行规则永远建不出来。两者现在分开判断。
need_v4=0
if [ -n "$FORWARD_TARGET_PORT" ] && [ -n "$FORWARD_TARGET_IP" ]; then
	need_v4=1
fi

# IPv6 放行由 firewall 插件实现（ikuai 插件没有这条逻辑）
need_v6=0
if [ "${LINK_ENABLE}" = 1 ] && [ "${FORWARD_MODE}" = firewall ]; then
	case "${LINK_MODE}" in
	qbittorrent)
		[ "${LINK_QB_ALLOW_IPV6}" = 1 ] && need_v6=1
		;;
	transmission)
		[ "${LINK_TR_ALLOW_IPV6}" = 1 ] && need_v6=1
		;;
	esac
fi

# 两个方向都不需要时**不能直接退出**。
#
# 功能刚被关掉（清空转发目标 / 关掉 IPv6 放行）时，上一次写进防火墙的段还留在
# uci 与内核里，而**只有插件知道该删哪些段名** —— 这里一 exit，退役清理就永远
# 跑不到，那条 DNAT / ACCEPT 会一直生效：用户以为已经关了，外部其实还能打进来。
#
# 所以 firewall 模式下仍把插件叫起来（插件内部 do_v4=do_v6=0 时不会写任何新规则，
# 只删不再需要的段；没有可删的就什么都不做）。ikuai 插件没有这套清理逻辑，
# 保持原样直接跳过。
if [ "$need_v4" = 0 ] && [ "$need_v6" = 0 ] && [ "${FORWARD_MODE}" != firewall ]; then
	exit 0
fi

# 设置重试次数和时间间隔
max_retries=1
sleep_time=1

# 判断是否开启高级功能
if [ "${FORWARD_ADVANCED_ENABLE}" == 1 ]; then
	max_retries=$FORWARD_ADVANCED_MAX_RETRIES
	sleep_time=$FORWARD_ADVANCED_SLEEP_TIME
else
	# 默认重试次数为1，休眠时间为1s
	max_retries=1
	sleep_time=1
fi

forward_script=""
case $FORWARD_MODE in
"firewall")
    forward_script="/usr/share/natmap/plugin-forward/firewall-forward.sh"
    ;;
"ikuai")
    forward_script="/usr/share/natmap/plugin-forward/ikuai-forward.sh"
    ;;
*)
    forward_script=""
    ;;
esac

if [ -n "${forward_script}" ]; then
    echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute forward script" >>/var/log/natmap/natmap.log
    echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute forward script"
    bash "$forward_script" "$outter_ip" "$outter_port" "$ip4p" "$inner_port" "$protocol" "$max_retries" "$sleep_time"
fi
