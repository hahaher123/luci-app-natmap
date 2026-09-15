#!/bin/bash

text="$1"
chat_id="${NOTIFY_TELEGRAM_BOT_CHAT_ID}"
token="${NOTIFY_TELEGRAM_BOT_TOKEN}"
title="natmap - ${GENERAL_NAT_NAME} 更新"

function curl_proxy() {
    if [ -z "$NOTIFY_TELEGRAM_BOT_PROXY" ]; then
        curl -m 15 "$@"
    else
        # 代理地址加引号，避免含特殊字符时被拆分
        curl -x "$NOTIFY_TELEGRAM_BOT_PROXY" -m 15 "$@"
    fi
}

# 获取最大重试次数和间隔时间
max_retries=$2
sleep_time=$3
retry_count=0

while (true); do

    # 用 jq 构建请求体，避免消息中含引号/换行时破坏 JSON
    payload=$(jq -n --arg chat_id "$chat_id" --arg text "${title}

${text}" \
        '{chat_id: $chat_id, text: $text, parse_mode: "HTML", disable_notification: false}')

    status=$(curl_proxy -4 -s -m 15 -o /dev/null -w "%{http_code}" -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "https://api.telegram.org/bot${token}/sendMessage")
    if [ "$status" = "200" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $NOTIFY_MODE 发送成功" >>/var/log/natmap/natmap.log
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $NOTIFY_MODE 发送成功"
        break
    fi

    # 检测剩余重试次数
    let retry_count++
    if [ $retry_count -lt $max_retries ] || [ $max_retries -eq 0 ]; then
        echo "$NOTIFY_MODE 登录失败,休眠$sleep_time秒" >>/var/log/natmap/natmap.log
        sleep $sleep_time
    else
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $NOTIFY_MODE 达到最大重试次数，无法通知" >>/var/log/natmap/natmap.log
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $NOTIFY_MODE 达到最大重试次数，无法通知"
        break
    fi
done
