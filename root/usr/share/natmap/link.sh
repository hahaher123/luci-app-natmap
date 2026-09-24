#!/bin/bash
# NATMap
outter_ip=$1
outter_port=$2
ip4p=$3
inner_port=$4
protocol=$5

link_script=""
# echo "LINK_MODE: $LINK_MODE"

# 重试次数与间隔：固定 10 次 / 5 秒，不再提供「高级设置」开关。
#
# link 动作全部依赖外网（Cloudflare API、qBittorrent/Emby 等的远端接口），而打洞成功
# 往往早于 DNS/TLS 就绪 —— natmap 只需 UDP/STUN 就能打洞，wait-network.sh 即使探测
# 失败也会在超时后照常启动 natmap，此时 oxidns/unbound 的 DoT 链路可能还没建好，
# 第一个请求必然失败。原来默认 1 次意味着「重启后的首次打洞 = 联动必然丢失」，
# 要等下次端口变化才补上。
# 10 次 / 5 秒（最长约 45 秒）足以覆盖重启后 DNS 就绪的窗口；成功即 break，
# 不会因为次数多而拖慢正常路径。
max_retries=10
sleep_time=5

# 如果$LINK_MODE非空则执行对应的脚本
case "${LINK_MODE}" in
"cloudflare_ddns")
	link_script="/usr/share/natmap/plugin-link/cloudflare_ddns.sh"
	;;
"cloudflare_origin_rule")
	link_script="/usr/share/natmap/plugin-link/cloudflare_origin_rule.sh"
	;;
"cloudflare_redirect_rule")
	link_script="/usr/share/natmap/plugin-link/cloudflare_redirect_rule.sh"
	;;
"emby")
	link_script="/usr/share/natmap/plugin-link/emby.sh"
	;;
"qbittorrent")
	link_script="/usr/share/natmap/plugin-link/qbittorrent.sh"
	;;
"transmission")
	link_script="/usr/share/natmap/plugin-link/transmission.sh"
	;;
*)
	link_script=""
	;;
esac

# if [ -n "${LINK_MODE}" ]; then
#     link_script="/usr/share/natmap/plugin-link/${LINK_MODE}.sh"
# fi

if [ -n "${link_script}" ]; then
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute link script (最多尝试 $max_retries 次, 间隔 $sleep_time 秒)" >>/var/log/natmap/natmap.log
	echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME execute link script (最多尝试 $max_retries 次, 间隔 $sleep_time 秒)"
	bash "${link_script}" "$outter_ip" "$outter_port" "$ip4p" "$inner_port" "$protocol" "$max_retries" "$sleep_time"
fi
