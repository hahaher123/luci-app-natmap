#!/bin/bash

# NATMap
outter_ip=$1
outter_port=$2

function get_current_rule() {
  curl -m 20 --request GET \
    --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/phases/http_request_dynamic_redirect/entrypoint" \
    --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
    --header "Content-Type: application/json"
}

# 默认重试次数为1，休眠时间为3s
max_retries=$6
sleep_time=$7
retry_count=0

# 初始化参数
currrent_rule=""
cloudflare_ruleset_id=""

# 获取cloudflare redirect rule id
while (true); do
  currrent_rule=$(get_current_rule)
  cloudflare_ruleset_id=$(echo "$currrent_rule" | jq '.result.id' | sed 's/"//g')

  if [ -n "$cloudflare_ruleset_id" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 登录成功" >>/var/log/natmap/natmap.log

    # 按规则名称(description)定位规则索引
    rule_idx=$(echo "$currrent_rule" | jq -r --arg name "$LINK_CLOUDFLARE_REDIRECT_RULE_NAME" '.result.rules | to_entries | map(select(.value.description == $name) | .key) | first // empty' 2>/dev/null)

    if [ -z "$rule_idx" ]; then
      echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 未找到名为 $LINK_CLOUDFLARE_REDIRECT_RULE_NAME 的规则" >>/var/log/natmap/natmap.log
      echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 未找到名为 $LINK_CLOUDFLARE_REDIRECT_RULE_NAME 的规则"
    else
      # 替换 NEW_PORT 占位符为当前打洞端口
      redirect_rule_target_url=$(echo "$LINK_CLOUDFLARE_REDIRECT_RULE_TARGET_URL" | sed 's/NEW_PORT/'"$outter_port"'/g')

      # 统一写入 target_url.value（静态跳转形式，接受纯 URL）。
      # 注意：动态跳转规则(target_url.expression)不接受裸 URL 字面量，
      # 若原规则是动态类型，这里整体替换 target_url 会自动转为静态类型。
      new_rule=$(echo "$currrent_rule" | jq --arg url "$redirect_rule_target_url" ".result.rules[$rule_idx].action_parameters.from_value.target_url = {\"value\": \$url}")

      request_data=$(echo "$new_rule" | jq '.result | del(.last_updated)')
      result=$(curl -m 20 --request PUT \
        --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/$cloudflare_ruleset_id" \
        --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$request_data")

      if [ "$(echo "$result" | jq -r '.success')" == "true" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功: $redirect_rule_target_url" >>/var/log/natmap/natmap.log
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功: $redirect_rule_target_url"
        break
      else
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改失败: $(echo "$result" | jq -c '.errors' 2>/dev/null)" >>/var/log/natmap/natmap.log
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改失败,休眠$sleep_time秒" >>/var/log/natmap/natmap.log
      fi
    fi
  else
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 登录失败,休眠$sleep_time秒" >>/var/log/natmap/natmap.log
  fi

  # 检测剩余重试次数
  let retry_count++
  if [ $retry_count -lt $max_retries ] || [ $max_retries -eq 0 ]; then
    sleep $sleep_time
  else
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 达到最大重试次数，无法修改" >>/var/log/natmap/natmap.log
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 达到最大重试次数，无法修改"
    break
  fi
done
