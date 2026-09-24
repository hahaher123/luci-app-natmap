#!/bin/bash

# NATMap
outter_ip=$1
outter_port=$2
ip4p=$3

# 默认重试次数为1，休眠时间为3s
max_retries=$6
sleep_time=$7
retry_count=0

# 初始化参数
dns_type=$LINK_CLOUDFLARE_DDNS_TYPE
dns_record_id=""

# 只写日志文件。本脚本里 get_dns_record_id / update_dns_record 都用 stdout 返回结果，
# 日志不能走 stdout，否则会污染返回值。
function log_file() {
  echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE $*" >>/var/log/natmap/natmap.log
}

# 失败原因描述。优先报 curl 退出码 —— 传输层失败时响应体是空的，
# 只看 jq '.errors' 会得到空串，无从定因。
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

# 获取dns_record_id
# @param {string} local_ddns_domain - The domain name
# @param {string} local_dns_types - The DNS record type
# @return {string} The DNS record ID
function get_dns_record_id() {
  local local_ddns_domain="$1"
  local local_dns_types="$2"
  local local_dns_record_id=""
  local local_dns_record=""
  local local_rc=0

  # 获取cloudflare dns记录的dns_record
  local_dns_record=$(curl -m 20 --request GET \
    --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/dns_records?name=$local_ddns_domain&type=$local_dns_types" \
    --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
    --header "Content-Type: application/json" 2>/dev/null)
  local_rc=$?

  # 判断是否成功获取响应
  if [ "$(printf '%s' "$local_dns_record" | jq -r '.success' 2>/dev/null)" == "true" ]; then
    log_file "登录成功"
    # // empty：记录不存在时 .result 是空数组，jq 会把字面量 "null" 输出来，
    # 那会让调用方的 [ -z "$dns_record_id" ] 判断失效，转而向 .../dns_records/null 发无效 PUT
    local_dns_record_id=$(printf '%s' "$local_dns_record" | jq -r '.result[0].id // empty' 2>/dev/null)
  else
    # 失败时静默会让调用方只看到"未找到记录"，分不清是 API 不通还是记录真的不存在
    log_file "获取 $local_dns_types 记录($local_ddns_domain)失败: $(describe_failure "$local_dns_record" "$local_rc")"
  fi

  # 返回dns记录的id
  echo "$local_dns_record_id"
}

# 创建请求数据
# @param {string} local_dns_type - dns记录类型
# @return {string} - 请求数据
function generate_request_data() {
  local local_dns_type="$1"

  # 构建请求数据
  local local_request_data=""
  case $local_dns_type in
  "AAAA")
    # 创建 AAAA 记录
    local_request_data="{
                \"type\": \"$local_dns_type\",
                \"name\": \"$LINK_CLOUDFLARE_DDNS_DOMAIN\",
                \"content\": \"$ip4p\",
                \"ttl\": $LINK_CLOUDFLARE_DDNS_TTL,
                \"proxied\": false
            }"
    ;;
  "HTTPS")
    # 创建 HTTPS 记录
    local_request_data="{
                \"name\": \"$LINK_CLOUDFLARE_DDNS_DOMAIN\",
                \"type\": \"$local_dns_type\",
                \"proxied\": false,
                \"ttl\": $LINK_CLOUDFLARE_DDNS_TTL,
                \"data\":{
                    \"priority\": $LINK_CLOUDFLARE_DDNS_HTTPS_PRIORITY,
                    \"target\": \".\",
                    \"value\": \"ipv4hint=\\\"$outter_ip\\\" port=\\\"$outter_port\\\"\"
                }}"
    ;;
  "SRV")
    # 创建 SRV 记录
    local_request_data="{
                \"name\": \"$LINK_CLOUDFLARE_DDNS_DOMAIN\",
                \"type\": \"$local_dns_type\",
                \"ttl\": $LINK_CLOUDFLARE_DDNS_TTL,
                \"data\":{
                    \"port\": $outter_port,
                    \"priority\": $LINK_CLOUDFLARE_DDNS_SRV_PRIORITY,
                    \"target\": \"$LINK_CLOUDFLARE_DDNS_SRV_TARGET_DOMAIN\",
                    \"weight\": $LINK_CLOUDFLARE_DDNS_SRV_WEIGHT
                }}"
    ;;
  "A")
    # 创建 A 记录
    local_request_data="{
                \"type\": \"$local_dns_type\",
                \"name\": \"$LINK_CLOUDFLARE_DDNS_SRV_TARGET_DOMAIN\",
                \"content\": \"$outter_ip\",
                \"ttl\": $LINK_CLOUDFLARE_DDNS_TTL,
                \"proxied\": false
            }"
    ;;
  *)
    # 未知类型
    local_request_data=""
    ;;
  esac
  echo "$local_request_data"
}

# 更新dns记录
# @param {string} local_dns_record_id - dns记录的id
# @param {string} local_request_data - 请求数据
# @return {string} - 更新结果
function update_dns_record() {
  local local_dns_record_id="$1"
  local local_request_data="$2"
  local local_result=""
  local local_rc=0

  local_result=$(curl -m 20 --request PUT \
    --url "https://api.cloudflare.com/client/v4/zones/$LINK_CLOUDFLARE_ZONE_ID/dns_records/$local_dns_record_id" \
    --header "Authorization: Bearer $LINK_CLOUDFLARE_TOKEN" \
    --header "Content-Type: application/json" \
    --data "$local_request_data" 2>/dev/null)
  local_rc=$?

  # 判断api是否调用成功,返回参数success是否为true
  if [ "$(printf '%s' "$local_result" | jq -r '.success' 2>/dev/null)" == "true" ]; then
    echo "true"
  else
    # 诊断只落日志文件，本函数的 stdout 是返回值
    log_file "提交 DNS 记录失败($local_dns_record_id): $(describe_failure "$local_result" "$local_rc")"
    echo "false"
  fi
}

# 开始运行
# 初始化输出参数
result="false"
# 更新cloudflare的dns记录
while (true); do
  case $dns_type in
  "AAAA")
    # 更新 AAAA 记录
    request_data="$(generate_request_data "$dns_type")"
    dns_record_id="$(get_dns_record_id "$LINK_CLOUDFLARE_DDNS_DOMAIN" "$dns_type")"
    # 记录不存在时直接报错重试，避免向 .../dns_records/ 空 id 发起无效 PUT
    if [ -z "$dns_record_id" ]; then
      log_file "未找到 $dns_type 记录($LINK_CLOUDFLARE_DDNS_DOMAIN), 请先在 Cloudflare 添加该记录"
      result="false"
    else
      result="$(update_dns_record "$dns_record_id" "$request_data")"
    fi

    # 判断api是否调用成功
    if [ "$result" == "true" ]; then
      log_file "修改成功"
      echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功"
      break
    else
      log_file "修改失败,休眠$sleep_time秒"
    fi
    ;;
  "HTTPS")
    # 更新 HTTPS 记录
    request_data="$(generate_request_data "$dns_type")"
    dns_record_id="$(get_dns_record_id "$LINK_CLOUDFLARE_DDNS_DOMAIN" "$dns_type")"
    if [ -z "$dns_record_id" ]; then
      log_file "未找到 $dns_type 记录($LINK_CLOUDFLARE_DDNS_DOMAIN), 请先在 Cloudflare 添加该记录"
      result="false"
    else
      result="$(update_dns_record "$dns_record_id" "$request_data")"
    fi

    # 判断api是否调用成功
    if [ "$result" == "true" ]; then
      log_file "修改成功"
      echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功"
      break
    else
      log_file "修改失败,休眠$sleep_time秒"
    fi
    ;;
  "SRV")
    # 更新target_domain的A记录
    dns_type="A"
    request_data="$(generate_request_data "$dns_type")"
    dns_record_id="$(get_dns_record_id "$LINK_CLOUDFLARE_DDNS_SRV_TARGET_DOMAIN" "$dns_type")"
    if [ -z "$dns_record_id" ]; then
      log_file "未找到 $dns_type 记录($LINK_CLOUDFLARE_DDNS_SRV_TARGET_DOMAIN), 请先在 Cloudflare 添加该记录"
      result="false"
    else
      result="$(update_dns_record "$dns_record_id" "$request_data")"
    fi

    # 判断api是否调用成功，成功则继续下一步，更新SRV记录
    if [ "$result" == "true" ]; then
      # 更新SRV记录
      dns_type="SRV"
      request_data="$(generate_request_data "$dns_type")"
      dns_record_id="$(get_dns_record_id "$LINK_CLOUDFLARE_DDNS_DOMAIN" "$dns_type")"
      if [ -z "$dns_record_id" ]; then
        log_file "未找到 $dns_type 记录($LINK_CLOUDFLARE_DDNS_DOMAIN), 请先在 Cloudflare 添加该记录"
        result="false"
      else
        result="$(update_dns_record "$dns_record_id" "$request_data")"
      fi

      # 判断api是否调用成功
      if [ "$result" == "true" ]; then
        log_file "修改成功"
        echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 修改成功"
        break
      else
        log_file "修改失败,休眠$sleep_time秒"
      fi
    else
      log_file "修改失败,休眠$sleep_time秒"
    fi
    ;;
  *) ;;
  esac

  # 检测剩余重试次数
  let retry_count++
  if [ $retry_count -lt $max_retries ] || [ $max_retries -eq 0 ]; then
    sleep $sleep_time
  else
    echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 达到最大重试次数，无法修改" >>/var/log/natmap/natmap.log
    echo "$(TZ='CST-8' date +'%Y-%m-%d %H:%M:%S') : $GENERAL_NAT_NAME - $LINK_MODE 达到最大重试次数，无法修改"
    break
  fi
done
