#!/bin/bash

text="$1"
chat_id="${NOTIFY_TELEGRAM_BOT_CHAT_ID}"
token="${NOTIFY_TELEGRAM_BOT_TOKEN}"
title="natmap - ${GENERAL_NAT_NAME} 更新"

# 尝试次数与间隔（由 notify.sh 传入）。这里再做一次兜底，
# 参数缺失或非法时不会退化成「只试一次」。
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

function curl_proxy() {
	if [ -z "$NOTIFY_TELEGRAM_BOT_PROXY" ]; then
		curl -m 15 "$@"
	else
		# 代理地址加引号，避免含特殊字符时被拆分
		curl -x "$NOTIFY_TELEGRAM_BOT_PROXY" -m 15 "$@"
	fi
}

# parse_mode 为 HTML 时，正文里的 & < > 必须转义：不转义 Telegram 会直接返回
# 400（整条请求被拒），而且重试多少次都不会成功。固定模板里没有 HTML 标签，
# 转义只影响 general_nat_name 这类用户可填内容，属纯加固。
function html_escape() {
	local s="$1"

	# bash 5.2 起 patsub_replacement 默认开启：${var//pat/repl} 的 repl 里
	# 未转义的 & 会被展开成“被匹配到的内容”，于是 "&lt;" 会变成 "<lt;"
	# （实测 bash 5.3.15）。必须显式关掉；更早的 bash 没有这个选项，
	# shopt 会因“无效选项”报错并返回非 0，这里静默忽略，而那时 & 本就是字面量。
	shopt -u patsub_replacement 2>/dev/null

	s="${s//&/&amp;}"
	s="${s//</&lt;}"
	s="${s//>/&gt;}"
	printf '%s' "$s"
}

# 用 jq 构建请求体，避免消息中含引号/换行时破坏 JSON
payload=$(jq -n --arg chat_id "$chat_id" --arg text "$(html_escape "${title}

${text}")" \
	'{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_notification: false}')

attempt=0
while :; do
	attempt=$((attempt + 1))

	# 末尾追加一个换行再输出状态码，便于把响应体与状态码分开取；
	# 保留响应体是为了在失败时能给出服务端的具体原因
	resp=$(curl_proxy -4 -s -w '\n%{http_code}' -X POST \
		-H 'Content-Type: application/json' \
		-d "$payload" \
		"https://api.telegram.org/bot${token}/sendMessage")
	rc=$?
	status="${resp##*$'\n'}"
	body="${resp%$'\n'*}"
	# 截断后再进日志，避免把整段响应刷进日志
	detail="${body:0:200}"
	[ -n "$detail" ] || detail="curl 退出码 ${rc}, 无响应体"

	if [ "$status" = "200" ]; then
		log "发送成功(第 ${attempt} 次尝试)"
		exit 0
	fi

	case "$status" in
	429)
		# Telegram 限流（同一 chat 约 1 条/秒），响应体里给出应等待的秒数。
		# 固定间隔重试往往还没到可发送时刻，会继续撞限流。
		retry_after=$(printf '%s' "$body" | jq -r '.parameters.retry_after // empty' 2>/dev/null)
		case "$retry_after" in
		'' | *[!0-9]*) wait_s="$sleep_time" ;;
		*) wait_s=$((retry_after + 1)) ;;
		esac
		;;
	4??)
		# 其余 4xx 是请求本身的问题（token / chat_id / 消息格式），
		# 重试不会成功，直接放弃并把服务端原因写进日志
		log "请求被拒绝(HTTP ${status}), 不再重试: ${detail}"
		exit 1
		;;
	*)
		# 5xx / 000(连接失败、DNS 未就绪、代理未就绪、超时) —— 可重试
		wait_s="$sleep_time"
		;;
	esac

	# 上限保护：429 给出的等待时间可能很长（Telegram 会随重复触发递增）
	[ "$wait_s" -gt 60 ] 2>/dev/null && wait_s=60

	if [ "$max_attempts" != 0 ] && [ "$attempt" -ge "$max_attempts" ]; then
		log "达到最大尝试次数(${max_attempts}), 发送失败: HTTP ${status} ${detail}"
		exit 1
	fi

	log "第 ${attempt} 次发送失败(HTTP ${status}), ${wait_s} 秒后重试: ${detail}"
	sleep "$wait_s"
done
