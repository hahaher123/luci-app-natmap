#!/bin/bash
# NATMap
outter_ip=$1
outter_port=$2
ip4p=$3
inner_port=$4
protocol=$(echo $5 | tr 'a-z' 'A-Z')

# 构建消息内容
msg="${GENERAL_NAT_NAME}
New ${protocol} port mapping: ${inner_port} -> ${outter_ip}:${outter_port}
IP4P: ${ip4p}"
if [ ! -z "$MSG_OVERRIDE" ]; then
	msg="$MSG_OVERRIDE"
fi

# 设置重试次数和时间间隔
# 打洞成功的映射变化只触发一次，通知失败不会被重发，因此默认必须留出重试窗口：
# PPPoE 重拨后 DNS / 上游代理可能尚未就绪，单次尝试失败就放弃等于直接丢通知。
# 0 表示不限次数（沿用高级设置的语义）。
max_retries=5
sleep_time=3

# 判断是否开启高级功能
if [ "${NOTIFY_ADVANCED_ENABLE}" == 1 ]; then
	max_retries="${NOTIFY_ADVANCED_MAX_RETRIES:-5}"
	sleep_time="${NOTIFY_ADVANCED_SLEEP_TIME:-3}"
fi

# 数值兜底：配置为空或含非数字时回落到默认值，避免插件里算术比较报错
case "$max_retries" in
'' | *[!0-9]*) max_retries=5 ;;
esac
case "$sleep_time" in
'' | *[!0-9]*) sleep_time=3 ;;
esac

# notify_mode 判断
notify_script=""
case $NOTIFY_MODE in
"telegram_bot")
	notify_script="/usr/share/natmap/plugin-notify/telegram_bot.sh"
	;;
"pushplus")
	notify_script="/usr/share/natmap/plugin-notify/pushplus.sh"
	;;
"serverchan")
	notify_script="/usr/share/natmap/plugin-notify/serverchan.sh"
	;;
"gotify")
	notify_script="/usr/share/natmap/plugin-notify/gotify.sh"
	;;
*)
	notify_script=""
	;;
esac

# # 如果$NOTIFY_MODE非空则执行对应的脚本
# if [ -n "${NOTIFY_MODE}" ]; then
# 	notify_script="/usr/share/natmap/plugin-notify/$NOTIFY_MODE.sh"
# fi

if [ -n "${notify_script}" ]; then
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute notify script (最多尝试 ${max_retries} 次, 间隔 ${sleep_time} 秒)" >>/var/log/natmap/natmap.log
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute notify script"
	bash "$notify_script" "$msg" "$max_retries" "$sleep_time"
fi
