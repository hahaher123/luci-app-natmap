#!/bin/bash

# Define the Gotify URL, title, message, and priority
title="natmap - ${GENERAL_NAT_NAME} 更新"
message="$1"
gotify_url="${NOTIFY_GOTIFY_URL}"
priority="${NOTIFY_GOTIFY_PRIORITY:-5}"
token="${NOTIFY_GOTIFY_TOKEN}"

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

attempt=0
while :; do
	attempt=$((attempt + 1))

	# 检查 HTTP 状态码而非仅 curl 退出码：服务端返回 4xx/5xx 时
	# curl 退出码仍为 0，旧写法会把失败误判为"发送成功"而不再重试
	resp=$(curl -s -m 15 -w '\n%{http_code}' -X POST -H "Content-Type: multipart/form-data" -F "token=$token" -F "title=$title" -F "message=$message" -F "priority=$priority" "$gotify_url/message")
	rc=$?
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	detail="${body:0:200}"
	[ -n "$detail" ] || detail="curl 退出码 ${rc}, 无响应体"

	if [ "$status" = "200" ] || [ "$status" = "201" ]; then
		log "发送成功(第 ${attempt} 次尝试)"
		exit 0
	fi

	case "$status" in
	429)
		# 服务端限流：按配置间隔重试（脚本未取响应头，不解析 Retry-After）
		wait_s="$sleep_time"
		;;
	4??)
		# 其余 4xx 是请求本身的问题（地址 / token / 消息格式），重试不会成功
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
