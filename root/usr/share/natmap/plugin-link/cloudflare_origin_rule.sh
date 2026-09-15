#!/bin/bash

# NATMap
outter_ip=$1
outter_port=$2

function get_current_rule() {
  # Function to get the current rule
  #
  # Returns:
  #  string: The current rule
  curl -m 20 --request GET \
    --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/phases/http_request_origin/entrypoint" \
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

# 获取cloudflare origin rule id
while (true); do
  currrent_rule=$(get_current_rule)
  cloudflare_ruleset_id=$(echo "$currrent_rule" | jq '.result.id' | sed 's/"//g')

  if [ -n "$cloudflare_ruleset_id" ]; then
    echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 登录成功" >>/var/log/natmap/natmap.log

    # 按规则名称(description)定位规则索引
    rule_idx=$(echo "$currrent_rule" | jq -r --arg name "$LINK_CLOUDFLARE_ORIGIN_RULE_NAME" '.result.rules | to_entries | map(select(.value.description == $name) | .key) | first // empty' 2>/dev/null)

    if [ -z "$rule_idx" ]; then
      echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 未找到名为 $LINK_CLOUDFLARE_ORIGIN_RULE_NAME 的规则" >>/var/log/natmap/natmap.log
      echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 未找到名为 $LINK_CLOUDFLARE_ORIGIN_RULE_NAME 的规则"
    else
      # 更新 origin 回源端口为当前打洞端口
      new_rule=$(echo "$currrent_rule" | jq --argjson port "$outter_port" ".result.rules[$rule_idx].action_parameters.origin.port = \$port")

      request_data=$(echo "$new_rule" | jq '.result | del(.last_updated)')
      result=$(curl -m 20 --request PUT \
        --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/$cloudflare_ruleset_id" \
        --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$request_data")

      if [ "$(echo "$result" | jq -r '.success')" == "true" ]; then
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功: origin port -> $outter_port" >>/var/log/natmap/natmap.log
        echo "$(date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功: origin port -> $outter_port"
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
