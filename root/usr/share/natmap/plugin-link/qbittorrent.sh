#!/bin/bash
# ============================================================
# NATMap qBittorrent 端口同步（v4）
# 兼容 qBittorrent 4.x / 5.0 / 5.1 / 5.2.x（含 Enhanced Edition）
#
# 认证方式二选一，由 LINK_QB_AUTH_MODE 决定：
#
#  password（默认）  用户名 + 密码：
#       POST /api/v2/auth/login 换会话 cookie，后续请求带 cookie。
#       老配置里没有 LINK_QB_AUTH_MODE 这个选项（升级上来时为空），
#       必须回落到本方式，否则升级后原有的账密联动会突然失效。
#
#  apikey            API Key（qBittorrent >= 5.2.0 / WebAPI >= 2.14.1）：
#       每个请求带 Authorization: Bearer <key>，无状态、不建会话。
#       两条与 cookie 会话不同的行为必须记住：
#         a) API Key **不能**用于 auth/* 端点，访问会返回 403 —— 所以这条路径
#            完全不碰 /api/v2/auth/login；
#         b) 服务端对 Bearer 请求跳过 CSRF 校验，因此不需要 Referer/Origin。
#       Key 在 qB 的「偏好设置 → WebUI → API Key」里生成/轮换，
#       形如 qbt_ 加 28 位随机字符；轮换后旧 key 立即失效。
#
# 历史修复（勿回退）：
#  1) qB 5.2.x 破坏性变更：cookie 由 SID 改为 QBT_SID_<WebUI端口>，
#     登录成功响应码由 200 改为 204。旧脚本按 SID 抓取必然失败。
#     => 改用 curl cookie jar(-c/-b)，完全不用关心 cookie 名。
#  2) CSRF / Host header 校验：cookie 模式下请求携带与 Host 同源的 Referer/Origin。
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
LINK_QB_AUTH_MODE=${LINK_QB_AUTH_MODE:-password}
API_KEY=${LINK_QB_API_KEY:-}
log() {
    echo "$(TZ='CST-8' date '+%Y-%m-%d %H:%M:%S') : ${GENERAL_NAT_NAME:-qbittorrent} : $*" | tee -a "$LOG"
}
if [ -z "$outter_port" ] || [ -z "$LINK_QB_WEB_URL" ]; then
    log "缺少必要参数。用法: qbittorrent.sh <outter_ip> <outter_port> [ip4p] [inner_port] [protocol] [max_retries] [sleep_time]"
    log "环境变量需设置: LINK_QB_WEB_URL / LINK_QB_AUTH_MODE(password|apikey) / LINK_QB_USERNAME / LINK_QB_PASSWORD / LINK_QB_API_KEY"
    exit 1
fi
# 缺凭据的报错按认证方式区分：只让对方那一套凭据成为必需项，
# 否则从账密切到 API Key 之后会被"没填密码"这种无关理由挡下来。
# 取值不合法直接报错，不做静默回落 —— 把 `apikeys` 这类拼错当密码模式处理的话，
# 报出来的是"没填账号密码"，用户会照着一条错的方向去查。
case "$LINK_QB_AUTH_MODE" in
apikey)
    if [ -z "$API_KEY" ]; then
        log "认证方式为 API Key, 但未设置 LINK_QB_API_KEY"
        exit 1
    fi
    ;;
password)
    if [ -z "$LINK_QB_USERNAME" ] || [ -z "$LINK_QB_PASSWORD" ]; then
        log "认证方式为用户名密码, 但未设置 LINK_QB_USERNAME / LINK_QB_PASSWORD"
        exit 1
    fi
    ;;
*)
    log "未知的认证方式: $LINK_QB_AUTH_MODE (可选 password 或 apikey)"
    exit 1
    ;;
esac
LINK_QB_WEB_URL=$(echo "$LINK_QB_WEB_URL" | sed 's/\/$//')
while true; do
    rm -f "$COOKIE_JAR"
    # 两种认证方式最终都收敛成同一份 curl 参数（auth_args），
    # 下面改端口的请求只有一处，不会再出现"只改了一条分支"的漏改。
    if [ "$LINK_QB_AUTH_MODE" = "apikey" ]; then
        auth_args=(-H "Authorization: Bearer $API_KEY")
        # Key 是否有效要真的问服务端一次：把「Key 不对」与「端口没改成」分开报，
        # 否则两种情况都只表现为 setPreferences 返回 403，日志里没法排查。
        # /api/v2/app/version 需要认证但无副作用，用它当探针。
        auth_code=$(curl -s -m 20 -o /dev/null -w "%{http_code}" \
            "${auth_args[@]}" "$LINK_QB_WEB_URL/api/v2/app/version")
        if [ "$auth_code" = "200" ]; then
            auth_ok=1
        else
            auth_ok=0
            log "$LINK_MODE API Key 认证失败(HTTP $auth_code), 请确认 key 有效且未被轮换"
        fi
    else
        # 登录：cookie jar 自动保存会话 cookie（无论叫 SID 还是 QBT_SID_<port>）
        # -w 的状态码是**追加在响应体之后**的，用 \n 分隔后拆开取，避免两者粘在一起
        login_resp=$(curl -s -m 20 -c "$COOKIE_JAR" -X POST \
            -H "Referer: ${LINK_QB_WEB_URL}/" \
            -H "Origin: ${LINK_QB_WEB_URL}" \
            --data-urlencode "username=$LINK_QB_USERNAME" \
            --data-urlencode "password=$LINK_QB_PASSWORD" \
            "$LINK_QB_WEB_URL/api/v2/auth/login" -w "\n%{http_code}")
        login_code=${login_resp##*$'\n'}
        login_body=${login_resp%$'\n'*}
        # 登录是否成功：看三个各自独立的信号（qB 源码 + 真 curl 8.13 实测核对过）
        #   ① jar 里真的有一行 cookie —— 最直接的一条，下面的请求就靠它。
        #      HttpOnly 的 cookie 在 jar 里带 "#HttpOnly_" 前缀（libcurl 用这个前缀
        #      标记 HttpOnly，见 cookie.c 的 cookie_output），而 qB 的会话 cookie
        #      恒定 setHttpOnly(true)，所以**不能把 # 开头的行一概丢掉** —— 要先
        #      还原前缀，再排掉注释行与空行。
        #   ② qB >= 5.2：成功后无返回体、状态码 204；凭据错 401（IP 被 ban 则 403）。
        #   ③ qB 4.x / 5.0 / 5.1：成功失败都是 200，只能看返回体 Ok. / Fails.
        # 旧写法 `[ -s "$COOKIE_JAR" ] && grep -vq '^#'` 是坏的：curl 不管有没有
        # 收到 cookie 都会写出 jar（3 行 # 注释 + 一行**空行**），那行空行不含 #，
        # 于是该判据恒为真 —— 密码错也判成登录成功，接着拿空 jar 去 setPreferences
        # 收 403，日志把人引向 CSRF 而不是密码。
        cookies=$(sed 's/^#HttpOnly_//' "$COOKIE_JAR" 2>/dev/null \
            | grep -c -v -e '^#' -e '^[[:space:]]*$')
        auth_ok=0
        case "$login_body" in *Ok.*) auth_ok=1 ;; esac
        [ "$login_code" = "204" ] && auth_ok=1
        [ "${cookies:-0}" -gt 0 ] && auth_ok=1
        # 明确的失败码压过其它信号（防返回体里出现巧合子串把 401 判成成功）
        case "$login_code" in 401|403) auth_ok=0 ;; esac
        if [ "$auth_ok" = "1" ]; then
            auth_args=(-b "$COOKIE_JAR" \
                -H "Referer: ${LINK_QB_WEB_URL}/" \
                -H "Origin: ${LINK_QB_WEB_URL}")
        else
            log "$LINK_MODE 登录失败(HTTP $login_code), 未获得会话 cookie: $login_body"
        fi
    fi
    if [ "$auth_ok" = "1" ]; then
        # 修改监听端口
        response=$(curl -s -m 20 -X POST \
            "${auth_args[@]}" \
            -d 'json={"listen_port":'$outter_port'}' \
            "$LINK_QB_WEB_URL/api/v2/app/setPreferences" -w "\n%{http_code}")
        # 必须把响应体与状态码拆开再比：-w 的 %{http_code} 是追加在响应体之后的，
        # 旧写法拿「响应体+状态码」整体与 "200" 比较，只要 qB 回了非空响应体就永远
        # 判失败，白白重试到上限 —— 而端口其实早就改好了。
        set_code=${response##*$'\n'}
        set_body=${response%$'\n'*}
        if [ "$set_code" = "200" ]; then
            log "$LINK_MODE 修改成功, 端口=$outter_port"
            exit 0
        else
            log "$LINK_MODE setPreferences 返回 $set_code (预期 200): $set_body"
        fi
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
