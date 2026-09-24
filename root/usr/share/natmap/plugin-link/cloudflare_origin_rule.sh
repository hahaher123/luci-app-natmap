#!/bin/bash

# NATMap
outter_ip=$1
outter_port=$2

# 默认重试次数为1，休眠时间为3s
max_retries=$6
sleep_time=$7
retry_count=0

# 初始化参数
currrent_rule=""
cloudflare_ruleset_id=""

# 最近一次请求的结果。用全局变量而非命令替换取回：$(...) 会把 curl 的退出码一起吞掉，
# 而传输层失败（DNS 解析失败 / 连不上 / TLS 握手失败）恰恰只能靠退出码区分。
curl_rc=0
curl_body=""

# 统一日志：同时写 /var/log/natmap/natmap.log 与 stdout（stdout 进系统日志，
# 便于路由器重启早期、tmpfs 日志目录还没建好时也能看到）
function log() {
  echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE $*" >>/var/log/natmap/natmap.log
  echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE $*"
}

# 失败原因描述。优先报 curl 退出码 —— 传输层失败时响应体是空的，
# 只看 jq '.errors' 会得到空串（这正是"修改失败: "后面什么都没有的原因），无从定因。
# 退出码速查：6=域名解析失败 7=连接被拒 28=超时 35=TLS 握手失败 60=证书校验失败
function describe_failure() {
  local body="$1"
  local rc="$2"

  if [ "$rc" -ne 0 ]; then
    printf 'curl 退出码 %s, 无响应体' "$rc"
  elif [ -z "$body" ]; then
    printf '响应为空'
  elif ! printf '%s' "$body" | jq -e . >/dev/null 2>&1; then
    printf '响应非 JSON(前160字符): %s' "$(printf '%s' "$body" | tr '\n\r\t' '   ' | cut -c1-160)"
  else
    printf 'CF 返回: %s' "$(printf '%s' "$body" | jq -c '{success: .success, errors: .errors}' 2>/dev/null)"
  fi
}

function get_current_rule() {
  curl_body=$(curl -m 20 --request GET \
    --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/phases/http_request_origin/entrypoint" \
    --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
    --header "Content-Type: application/json" 2>/dev/null)
  curl_rc=$?
}

# 获取cloudflare origin rule id
while (true); do
  get_current_rule
  currrent_rule="$curl_body"
  get_rule_rc="$curl_rc"

  # 判据必须是 .success == true。
  # 不能再用 [ -n "$cloudflare_ruleset_id" ]：API 报错时 .result 为 null，
  # jq 会把字面量 "null" 输出出来，变量非空 → 被判成"登录成功"，
  # 随后又定位不到 rule_idx，日志上进一步给出误导性的"未找到名为 XXX 的规则"。
  if [ "$(printf '%s' "$currrent_rule" | jq -r '.success' 2>/dev/null)" == "true" ]; then
    cloudflare_ruleset_id=$(printf '%s' "$currrent_rule" | jq -r '.result.id' 2>/dev/null)
    log "登录成功"

    # 按规则名称(description)定位规则索引
    rule_idx=$(printf '%s' "$currrent_rule" | jq -r --arg name "$LINK_CLOUDFLARE_ORIGIN_RULE_NAME" '.result.rules | to_entries | map(select(.value.description == $name) | .key) | first // empty' 2>/dev/null)

    if [ -z "$rule_idx" ]; then
      log "未找到名为 $LINK_CLOUDFLARE_ORIGIN_RULE_NAME 的规则"
    else
      # 更新 origin 回源端口为当前打洞端口
      new_rule=$(printf '%s' "$currrent_rule" | jq --argjson port "$outter_port" ".result.rules[$rule_idx].action_parameters.origin.port = \$port")

      request_data=$(printf '%s' "$new_rule" | jq '.result | del(.last_updated)')
      result=$(curl -m 20 --request PUT \
        --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/rulesets/$cloudflare_ruleset_id" \
        --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
        --header "Content-Type: application/json" \
        --data "$request_data" 2>/dev/null)
      put_rc=$?

      if [ "$(printf '%s' "$result" | jq -r '.success' 2>/dev/null)" == "true" ]; then
        log "修改成功: origin port -> $outter_port"
        break
      else
        log "修改失败: $(describe_failure "$result" "$put_rc")"
        log "修改失败,休眠$sleep_time秒"
      fi
    fi
  else
    log "登录失败: $(describe_failure "$currrent_rule" "$get_rule_rc"),休眠$sleep_time秒"
  fi

  # 检测剩余重试次数
  let retry_count++
  if [ $retry_count -lt $max_retries ] || [ $max_retries -eq 0 ]; then
    sleep $sleep_time
  else
    log "达到最大重试次数，无法修改"
    break
  fi
done
