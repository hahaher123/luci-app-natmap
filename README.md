# luci-app-natmap（维护分支）

> [uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（原作者，**已归档**）的维护分支：在继承原作者设计、功能与 Apache-2.0 许可的前提下，适配新版 OpenWrt 与新版 qBittorrent。感谢原作者及上游 [EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)、[heiher/natmap](https://github.com/heiher/natmap)。

## ⚠️ 重要提示

- 原仓库已归档停更，本仓库独立维护，不保证与上游同步。
- **仅在公网 IP / NAT1（Full Cone）环境下有效**，请先确认宽带类型。
- 以 **OpenWrt 25.12** 为基准测试，面向 23.0+ / luci2 / golang≥1.20。
- 本人不会编程，改动由 AI 完成，仅供个人使用。

## ✨ 本分支改动

相对原作者版本的修复与新增。

| 类型 | 项目 | 作用 |
|---|---|---|
| 修复 | qBittorrent 端口联动 | 兼容 4.3+ / 5.x；密码含特殊字符也能登录并修改监听端口 |
| 修复 | Transmission / Emby 联动 | 凭据含特殊字符不再登录失败，不再无限重试 |
| 修复 | Cloudflare 联动 | DDNS 与跳转规则更新恢复正常，记录不存在时给出明确提示 |
| 修复 | 防火墙 IPv6 放行 | 放行规则恢复生效，不再误用 IPv4 目标端口、不再限制到某个 IPv6 网段；只开 IPv6 放行、没配 IPv4 转发时也能生效 |
| 修复 | 接口绑定 | 不再覆盖 WAN 接口、导致打洞失效 |
| 修复 | 通知插件 | 含 `&`、引号、换行的消息可正常发送；服务端报错不再误报「成功」并自动重试 |
| 修复 | 脚本健壮性 | 统一请求超时；不再并发写 uci / 防火墙冲突 |
| 修复 | 默认 STUN 服务器 | 改为可用的 `stun.cloudflare.com`（仅影响新安装） |
| 新增 | 自动放行 IPv6 端口 | 打开联动的 `Allow IPv6` 即自动放行打洞端口的 IPv6 入站（TCP + UDP），不限于某个网段，IPv6 后缀变化不受影响 |
| 新增 | 等待网络就绪 | 开机 / 网络重置时先等 WAN 就绪再打洞，等待有上限，超时照常启动 |
| 新增 | 断网自恢复 | 长时间断网不再永久停摆，网络恢复后自动重新打洞 |
| 新增 | 端口同步到防火墙 | 打洞成功后自动把外部端口写入指定防火墙规则 |
| 新增 | 执行日志 | LuCI 页面可查看打洞与插件的执行日志，支持自动刷新与清空 |

natmap 核心使用官方最新 **20260214**（与 OpenWrt 25.12 官方 feed 同版本）。

## 🚀 编译与安装

本仓库为**单包扁平布局**：仓库根目录即包本体。

### 编译 apk（OpenWrt SDK 单包编译，与 Releases 产物同一方式）

在**已解压的 OpenWrt SDK 目录内**执行（本包 `PKGARCH:=all`，与 SDK 架构无关）：

```sh
git clone https://github.com/hahaher123/luci-app-natmap.git package/luci-app-natmap
./scripts/feeds update -a
./scripts/feeds install -a
make defconfig
make package/luci-app-natmap/compile V=s -j$(nproc)

find bin/packages -name '*.apk'   # 产物：主包 + 中文翻译包
```

> 扁平布局**不能**用 `feeds.conf` 的 `src-git`——feed 只识别根目录下的一级子目录，仓库根目录自身的 `Makefile` 不算一个包。

依赖 `+natmap +jq +curl +openssl-util +bash`。`natmap` 本体由官方 feed 提供，编译时会作为依赖被顺带编出（架构相关，不属于本仓库产物）。若要随固件一起编译，同样克隆到 `package/luci-app-natmap`，勾选 `LuCI → 3. Applications → luci-app-natmap`。

### 直接安装预编译包（apk，OpenWrt 25.12+）

下载 [Releases](https://github.com/hahaher123/luci-app-natmap/releases) 里编译好的 apk（`PKGARCH:=all`，任何架构可用）：

```sh
apk add --allow-untrusted --force-overwrite ./luci-app-natmap-<版本>-r<修订>.apk
apk add --allow-untrusted --force-overwrite ./luci-i18n-natmap-zh-cn-<版本>-r<修订>.apk   # 中文界面
apk add --allow-untrusted --force-overwrite --upgrade ./luci-app-natmap-*.apk             # 升级
```

> 包未经官方签名，必须加 `--allow-untrusted`；需先装好 `natmap`，否则会因缺少依赖被拒绝安装。
> 本包与官方 `natmap` 包同名提供 `/etc/config/natmap` 与 `/etc/init.d/natmap`，必须加 `--force-overwrite` 覆盖，否则 apk 报文件冲突拒绝安装。

## 📦 功能总览（继承自原版）

打洞成功后自动联动的第三方服务：qBittorrent / Transmission / Emby / Cloudflare（Origin Rules、Redirect Rules、DDNS）；消息通知：Telegram Bot / PushPlus / Server酱 / Gotify；端口转发：natmap / 防火墙 DNAT / iKuai 端口映射；自定义脚本。

## ⚙️ 配置

入口：LuCI → 服务 → NATMap。

| 配置项 | 说明 |
|---|---|
| `general_wan_interface` | WAN 接口名（如 `wan`） |
| `general_wait_network` / `general_wait_network_timeout` | 是否等待网络就绪（默认 `1`）及最长等待秒数（默认 `120`） |
| `general_nat_protocol` / `general_ip_address_family` | `tcp` / `udp`；`ipv4` / `ipv6`（留空为双栈） |
| `general_interval` / `general_stun_server` | keepalive 间隔（秒）；STUN 服务器（默认 `stun.cloudflare.com`） |
| `general_http_server` / `general_bind_port` | HTTP 打洞服务器（TCP 模式）；绑定端口（单端口或范围） |

联动配置项由 `link_mode` 选择（`qbittorrent` / `transmission` / `emby` / `cloudflare_*`），各项含义见 LuCI 页面内说明。

**qBittorrent / Transmission 的 IPv6 放行**：公网 IPv6 没有 NAT，下载器的监听端口就是打洞拿到的外部端口，只需放「外部能进来」。打开联动的 `Allow IPv6` 即可：

- 按**端口**放行（同时放行 TCP 与 UDP），不写任何 IPv6 地址或网段 —— 设备的 IPv6 后缀通常是随机的隐私地址，按网段放行会随运营商重新下发 PD 而失效。
- 放行方向由 WAN 与「转发目标接口」决定，均自动识别为防火墙 zone 名，填 `lan2` 之类的网络名也能正确生效。
- 打洞端口变化时规则会自动更新。

**防火墙端口同步**：开启「自定义脚本」并指向内置脚本，默认写入规则 `nas_incoming_5` 的 `dest_port`。

```sh
uci set natmap.@natmap[0].custom_script_enable=1
uci set natmap.@natmap[0].custom_script_path=/usr/share/natmap/plugin-link/firewall_nas.sh
uci commit natmap && /etc/init.d/natmap restart
```

如需调整，编辑脚本顶部的 `RULE_NAME` / `RULE_DEST_IP` / `SYNC_PROTO`。

**执行日志**：页面**顶部**显示 `/var/log/natmap/natmap.log` 尾部，可手动或每 5 秒自动刷新，也可清空。日志落在 tmpfs（`/var` 是 `/tmp` 的符号链接），重启即清空、不写 flash；单文件超过 1 MB 时滚动为 `natmap.log.1`（只留一份）。时间戳固定按 UTC+8 输出，不受系统时区影响。

**Cloudflare Redirect Rules**：入口域名开橙云代理，跳转目标域名需为 DNS-only（灰云，解析到家宽公网 IP）；目标 URL 的端口位置用 `NEW_PORT` 占位，规则名需与控制台一致。

链路：`https://入口域名`（橙云）→ 302 → `http://ddns域名:打洞端口`（灰云直连）→ 路由器 DNAT → 内网服务。

## 📁 目录结构

```text
Makefile                        # 包定义
htdocs/…/view/natmap/natmap.js  # LuCI2 前端
po/                             # 翻译（en / zh_Hans）
root/etc/{config,init.d}/natmap # 默认配置模板 + procd 服务
root/usr/share/natmap/          # 回调入口 + link/forward/notify + plugin-*
.github/                        # 手动编译 workflow 与 Release 说明脚本
```

> natmap 核心程序不在此仓库内，由官方 feed（`packages/net/natmap`）提供。

## 🛠 常见问题

| 问题 | 排查 |
|---|---|
| 打洞失败 / 一直重试 | 确认宽带是公网 IP / NAT1；更换 STUN 服务器测试 |
| 开机后一直没有打洞 | 日志停在「等待网络就绪」即 WAN 未就绪或 STUN 探测不通过，超时后仍会启动；可临时设 `general_wait_network=0` |
| qB 端口改不动 | 核对 `link_qb_web_url`；域名访问需加入 qB 域名白名单；看 `/var/log/natmap/natmap.log` |
| 服务起不来 `validation failed` | `custom_script_path` 指向的文件必须存在 |
| Cloudflare 联动失败 | 规则名需与 `link_cloudflare_redirect_rule_name` 一致且已存在；DDNS 记录只更新不创建 |
| IPv6 能连接但下载器无响应 | 开启下载器「允许 IPv6」，并在联动页打开 `Allow IPv6`；放行已覆盖该端口，无需填写地址 |

## 📄 许可

继承原版许可：**Apache-2.0**（luci-app-natmap）、**MIT**（natmap 核心）。上游：[uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（已归档）、[EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)、[EkkoG/openwrt-natmap](https://github.com/EkkoG/openwrt-natmap)、[heiher/natmap](https://github.com/heiher/natmap)。
