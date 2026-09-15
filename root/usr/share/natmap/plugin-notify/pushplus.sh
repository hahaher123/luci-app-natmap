#!/bin/bash

text="$1"
title="natmap - ${GENERAL_NAT_NAME} 更新"
token="${NOTIFY_PUSHPLUS_TOKEN}"

# 获取最大重试次数和间隔时间
max_retries=$2
sleep_time=$3
retry_count=0

while (true); do

    # 用 jq 构建请求体，避免消息中含引号/换行时破坏 JSON
    payload=$(jq -n --arg token "$token" --arg content "$text" --arg title "$title" \
        '{token: $token, content: $content, title: $title}')

    status=$(curl -4 -s -m 15 -o /dev/null -w "%{http_code}" -X POST \
        -H 'Content-Type: application/json' \
        -d "$payload" \
        "http://www.pushplus.plus/send")
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
