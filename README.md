# luci-app-natmap（维护分支）

> 本仓库是 [uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（原作者，**已归档**）的维护分支。
> 在完全继承原作者设计、功能与 Apache-2.0 许可的前提下，针对新版 OpenWrt 与新版 qBittorrent 做了适配与新增。
> **感谢原作者**及上游 [EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)、[heiher/natmap](https://github.com/heiher/natmap) 的工作。

## ⚠️ 重要提示

- 原仓库 `uvswifft/openwrt-natmap` 已归档停更，本仓库独立维护，不保证与上游同步。
- **仅在公网 IP / NAT1（Full Cone）环境下有效**：运营商大范围 NAT4 后打洞基本失效，请先确认宽带类型。
- 面向 OpenWrt 23.0+ / luci2 / golang≥1.20，以 **OpenWrt 25.12** 为基准测试。
- 本人不会编程，改动由 AI 完成，仅供个人使用。

## ✨ 本分支改动一览

相对原作者版本的修复与新增。

### 修复

| 项目 | 作用 |
|---|---|
| qBittorrent 端口联动 | 兼容 4.3+ / 5.x（含 5.2.x）；密码含特殊字符也能登录并修改监听端口 |
| Transmission / Emby 联动 | 凭据含特殊字符不再登录失败，不再因状态码判断错误而无限重试 |
| Cloudflare 联动 | DDNS 与跳转规则更新恢复正常；记录不存在时给出明确提示，不再无效重试 |
| 防火墙 IPv6 放行 | 放行规则恢复生效，放行端口不再误用 IPv4 目标端口 |
| 接口绑定 | 不再覆盖 WAN 接口、导致打洞失效 |
| 通知插件 | 含引号、换行、`&`、`=` 的消息能正常发送；服务端报错不再误报「成功」，并会自动重试 |
| 脚本健壮性 | 统一请求超时；避免并发写 uci / 防火墙冲突；配置值含空格不再损坏环境变量 |
| 默认 STUN 服务器 | 由已停服的地址改为可用的 `stun.cloudflare.com`（仅影响新安装） |

### 新增

| 项目 | 作用 |
|---|---|
| 等待网络就绪 | 开机 / 网络重置时先等 WAN 就绪再打洞，等待有上限，超时照常启动、不阻塞打洞 |
| 断网自恢复 | 长时间断网不再使实例永久停摆，网络恢复后自动重新打洞 |
| 端口同步到防火墙 | 打洞成功后自动把外部端口写入指定防火墙规则 |

natmap 核心使用官方最新 **20260214**（与 OpenWrt 25.12 官方 feed 同版本）。

## 🚀 编译与安装

本仓库为**单包扁平布局**：仓库根目录即包本体，**不能**用 `feeds.conf` 的 `src-git` 添加（feed 只识别根目录下的一级子目录），请按包目录克隆进 OpenWrt 源码：

```sh
git clone https://github.com/hahaher123/luci-app-natmap.git package/luci-app-natmap
```

```sh
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig    # 勾选 Network → natmap / luci-app-natmap
make -j$(nproc)
```

依赖：`+natmap +jq +curl +openssl-util +bash`。其中 `natmap` 本体由 OpenWrt 官方 feed 提供，本仓库不含。建议编译固件时一并集成。

### 直接安装预编译包（apk，OpenWrt 25.12+）

下载 [Releases](https://github.com/hahaher123/luci-app-natmap/releases) 里编译好的 apk（`PKGARCH:=all`，任何架构可用）：

```sh
apk add --allow-untrusted ./luci-app-natmap-<版本>.apk
apk add --allow-untrusted ./luci-i18n-natmap-zh-cn-<版本>.apk   # 中文界面
apk add --allow-untrusted --upgrade ./luci-app-natmap-*.apk     # 升级
```

> 包未经 OpenWrt 官方签名，必须加 `--allow-untrusted`。需先装好 `natmap`，否则会因缺少依赖被拒绝安装。

## 🤖 手动编译发布（GitHub Actions）

`.github/workflows/build.yml` 用 OpenWrt SDK 在 GitHub 上编译 apk 并可发布 Release，无需本地编译环境。**仅手动触发**：

| 操作 | 行为 |
|---|---|
| Actions → Build & Release Packages → Run workflow | 按根目录 `Makefile` 的 `PKG_VERSION` 编译，并创建 / 更新对应 `v<版本>` Release |
| 同上，`version` 填具体版本号 | 用指定版本号打标签、发版 |
| 同上，勾选 `force` | 即使标签已存在也重新编译，并覆盖 Release 资产 |

产物为两个架构无关包：`luci-app-natmap-<版本>-r<revision>.apk`（本体）与 `luci-i18n-natmap-zh-cn-<版本>.apk`（简体中文）。

如需 ipk（OpenWrt 24.10 及更早），把 workflow 顶部的 `SDK_ARCH` 改为 `x86_64-24.10.7`，并把收集产物时的 `.apk` 换成 `.ipk`。CI 包默认未签名，在仓库 Secrets 里配置 `PRIVATE_KEY` 后会自动签名。

## 📦 功能总览（继承自原版）

- **第三方服务联动**（打洞成功后自动调用）：qBittorrent、Transmission、Emby、Cloudflare（Origin Rules / Redirect Rules / DDNS）
- **消息通知**：Telegram Bot / PushPlus / Server酱 / Gotify
- **端口转发**：natmap 转发 / OpenWrt firewall DNAT 转发 / iKuai 端口映射
- **自定义脚本**：打洞成功后执行自定义脚本（本分支的防火墙端口同步功能即基于此实现）

## ⚙️ 配置

入口：LuCI → 服务 → NATMap。常用项：

| 配置项 | 说明 |
|---|---|
| `general_wan_interface` | WAN 接口名（如 `wan`） |
| `general_wait_network` / `general_wait_network_timeout` | 是否等待网络就绪（默认 `1`）及最长等待秒数（默认 `120`）；超时后照常启动 |
| `general_nat_protocol` / `general_ip_address_family` | `tcp` / `udp`；`ipv4` / `ipv6`（留空为双栈） |
| `general_interval` | keepalive 间隔（秒） |
| `general_stun_server` | STUN 服务器（默认 `stun.cloudflare.com`） |
| `general_http_server` | HTTP 打洞服务器（TCP 模式使用） |
| `general_bind_port` | 绑定端口（单端口或范围） |

联动相关配置项由 `link_mode` 选择（`qbittorrent` / `transmission` / `emby` / `cloudflare_*`），各项含义见 LuCI 页面内说明。

### 防火墙端口同步

开启「自定义脚本」并指向本仓库内置脚本：

```sh
uci set natmap.@natmap[0].custom_script_enable=1
uci set natmap.@natmap[0].custom_script_path=/usr/share/natmap/plugin-link/firewall_nas.sh
uci commit natmap
/etc/init.d/natmap restart
```

默认写入防火墙规则 `nas_incoming_5` 的 `dest_port`（目标 IPv6 为空，即放行整个局域网的目标端口）。如需调整，编辑脚本顶部的 `RULE_NAME` / `RULE_DEST_IP` / `SYNC_PROTO`。

### Cloudflare Redirect Rules

入口域名需在 Cloudflare 开启代理（橙云），跳转目标域名需为 DNS-only（灰云，解析到家宽公网 IP）。目标 URL 的**端口位置**用 `NEW_PORT` 占位，规则名需与控制台创建的规则名一致。

跳转链路：`https://入口域名`（橙云）→ 302 → `http://ddns域名:打洞端口`（灰云直连）→ 路由器 DNAT → 内网服务。

## 📁 目录结构

```text
Makefile                        # 包定义
htdocs/…/view/natmap/natmap.js  # LuCI2 前端
po/                             # 翻译（en 英文原文 / zh_Hans 简体中文）
root/etc/config/natmap          # 默认配置模板
root/etc/init.d/natmap          # procd 服务
root/usr/share/natmap/          # update.sh 回调入口 + link/forward/notify + plugin-*
.github/                        # 手动编译 workflow 与 Release 说明脚本
```

> natmap 核心程序不在此仓库内，由 OpenWrt 官方 feed（`packages/net/natmap`）提供。

## 🛠 常见问题

| 问题 | 排查 |
|---|---|
| 打洞失败 / 一直重试 | 确认宽带是公网 IP / NAT1；更换 STUN 服务器测试 |
| 开机后一直没有打洞 | 日志若停在「等待网络就绪」，说明 WAN 未就绪或 STUN 探测不通过（ICMP 被上游屏蔽时属误判），超时后仍会照常启动；可临时设 `general_wait_network=0` 排除探测影响 |
| qB 端口改不动 | 核对 `link_qb_web_url` 与 qB 实际地址；域名访问需加入 qB 域名白名单；看 `/var/log/natmap/natmap.log` |
| 防火墙规则未更新 | 确认 `custom_script_enable=1`，且脚本路径指向的文件真实存在 |
| 服务起不来 `validation failed` | `custom_script_path` 指向的文件必须存在 |
| Cloudflare 联动一直重试失败 | 规则名需与 `link_cloudflare_redirect_rule_name` 一致，且需先在控制台创建 |
| Cloudflare DDNS 提示「未找到记录」 | 记录需先在控制台手动创建，脚本只更新不创建 |
| IPv6 能连接但下载器无响应 | 开启下载器的「允许 IPv6」，并填好 `link_qb_ipv6_address` / `link_tr_ipv6_address` |
| `feeds install` 找不到本包 | 扁平布局不能用 `src-git`，请克隆到 `package/luci-app-natmap` |

## 📄 许可与致谢

- 本仓库继承原版许可：**Apache-2.0**（luci-app-natmap）与 **MIT**（natmap 核心）。
- 上游引用：[uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（原作者，已归档）、[EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)、[EkkoG/openwrt-natmap](https://github.com/EkkoG/openwrt-natmap)、[heiher/natmap](https://github.com/heiher/natmap)（natmap 核心程序）。
