#!/bin/bash
# ============================================================
# NATMap qBittorrent 端口同步（修复版 v3）
# 兼容 qBittorrent 4.x / 5.0 / 5.1 / 5.2.x（含 Enhanced Edition）
#
# 关键修复：
#  1) qB 5.2.x 破坏性变更：cookie 由 SID 改为 QBT_SID_<WebUI端口>，
#     登录成功响应码由 200 改为 204。旧脚本按 SID 抓取必然失败。
#     => 改用 curl cookie jar(-c/-b)，完全不用关心 cookie 名。
#  2) CSRF / Host header 校验：请求携带与 Host 同源的 Referer/Origin。
#  3) 密码用 --data-urlencode 编码，避免 & ^ 等特殊字符截断。
# ============================================================
outter_ip=${1:-}
outter_port=${2:-}
ip4p=${3:-}
inner_port=${4:-}
protocol=${5:-tcp}
max_retries=${6:-1}
sleep_time=${7:-3}
retry_count=0
LOG=/var/log/natmap/natmap.log
[ -d /var/log/natmap ] || mkdir -p /var/log/natmap
COOKIE_JAR=/tmp/natmap_qb.cookies
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-qbittorrent} : $*" | tee -a "$LOG"
}
if [ -z "$outter_port" ] || [ -z "$LINK_QB_WEB_URL" ] || [ -z "$LINK_QB_USERNAME" ] || [ -z "$LINK_QB_PASSWORD" ]; then
    log "缺少必要参数。用法: qbittorrent.sh <outter_ip> <outter_port> [ip4p] [inner_port] [protocol] [max_retries] [sleep_time]"
    log "环境变量需设置: LINK_QB_WEB_URL / LINK_QB_USERNAME / LINK_QB_PASSWORD"
    exit 1
fi
LINK_QB_WEB_URL=$(echo "$LINK_QB_WEB_URL" | sed 's/\/$//')
while true; do
    rm -f "$COOKIE_JAR"
    # 登录：cookie jar 自动保存会话 cookie（无论叫 SID 还是 QBT_SID_<port>）
    login_code=$(curl -s -m 20 -o /dev/null -w "%{http_code}" -c "$COOKIE_JAR" -X POST \
        -H "Referer: ${LINK_QB_WEB_URL}/" \
        -H "Origin: ${LINK_QB_WEB_URL}" \
        --data-urlencode "username=$LINK_QB_USERNAME" \
        --data-urlencode "password=$LINK_QB_PASSWORD" \
        "$LINK_QB_WEB_URL/api/v2/auth/login")
    # 判断是否拿到会话 cookie（jar 里有非注释行即成功）
    got_cookie=0
    if [ -s "$COOKIE_JAR" ] && grep -vq '^#' "$COOKIE_JAR"; then
        got_cookie=1
    fi
    if [ "$got_cookie" = "1" ]; then
        # 修改监听端口
        response=$(curl -s -m 20 -X POST \
            -b "$COOKIE_JAR" \
            -H "Referer: ${LINK_QB_WEB_URL}/" \
            -H "Origin: ${LINK_QB_WEB_URL}" \
            -d 'json={"listen_port":'$outter_port'}' \
            "$LINK_QB_WEB_URL/api/v2/app/setPreferences" -w "%{http_code}")
        if [ "$response" = "200" ]; then
            log "$LINK_MODE 修改成功, 端口=$outter_port"
            exit 0
        else
            log "$LINK_MODE setPreferences 返回 $response (非200)"
        fi
    else
        log "$LINK_MODE 登录失败(HTTP $login_code), 未获得会话 cookie"
    fi
    retry_count=$((retry_count + 1))
    if [ "$retry_count" -lt "$max_retries" ] || [ "$max_retries" -eq 0 ]; then
        log "正在重试 ($retry_count/$max_retries)..."
        sleep "$sleep_time"
    else
        log "达到最大重试次数, 无法修改端口"
        exit 1
    fi
done
