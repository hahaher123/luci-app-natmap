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

# 设置重试次数和时间间隔：固定 10 次 / 5 秒，不再提供「高级设置」开关。
#
# 打洞成功的映射变化只触发一次，通知失败不会被重发，因此必须留出足够的重试窗口：
# PPPoE 重拨 / 路由器重启后 DNS 与上游代理可能尚未就绪，单次尝试失败就等于直接丢通知
# （这正是当初「3 次打洞只收到 2 条」的成因）。最长约 45 秒；发送成功即停，
# 不会拖慢正常路径。
max_retries=10
sleep_time=5

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
