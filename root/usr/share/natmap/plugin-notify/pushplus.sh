#!/bin/bash

text="$1"
title="natmap - ${GENERAL_NAT_NAME} 更新"
token="${NOTIFY_PUSHPLUS_TOKEN}"

# 尝试次数与间隔（由 notify.sh 传入），参数缺失或非法时不会退化成「只试一次」
max_attempts="${2:-5}"
sleep_time="${3:-3}"
case "$max_attempts" in
'' | *[!0-9]*) max_attempts=5 ;;
esac
case "$sleep_time" in
'' | *[!0-9]*) sleep_time=3 ;;
esac

log() {
	echo "$(date +'%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME} - ${NOTIFY_MODE} $*" >>/var/log/natmap/natmap.log
	echo "$(date +'%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME} - ${NOTIFY_MODE} $*"
}

# 用 jq 构建请求体，避免消息中含引号/换行时破坏 JSON
payload=$(jq -n --arg token "$token" --arg content "$text" --arg title "$title" \
	'{token: $token, content: $content, title: $title}')

attempt=0
while :; do
	attempt=$((attempt + 1))

	resp=$(curl -4 -s -m 15 -w '\n%{http_code}' -X POST \
		-H 'Content-Type: application/json' \
		-d "$payload" \
		"http://www.pushplus.plus/send")
	rc=$?
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	detail="${body:0:200}"
	[ -n "$detail" ] || detail="curl 退出码 ${rc}, 无响应体"

	if [ "$status" = "200" ]; then
		log "发送成功(第 ${attempt} 次尝试)"
		exit 0
	fi

	case "$status" in
	429)
		wait_s="$sleep_time"
		;;
	4??)
		# 其余 4xx 是请求本身的问题（token / 消息格式），重试不会成功
		log "请求被拒绝(HTTP ${status}), 不再重试: ${detail}"
		exit 1
		;;
	*)
		# 5xx / 000(连接失败、DNS 未就绪、超时) —— 可重试
		wait_s="$sleep_time"
		;;
	esac

	[ "$wait_s" -gt 60 ] 2>/dev/null && wait_s=60

	if [ "$max_attempts" != 0 ] && [ "$attempt" -ge "$max_attempts" ]; then
		log "达到最大尝试次数(${max_attempts}), 发送失败: HTTP ${status} ${detail}"
		exit 1
	fi

	log "第 ${attempt} 次发送失败(HTTP ${status}), ${wait_s} 秒后重试: ${detail}"
	sleep "$wait_s"
done
