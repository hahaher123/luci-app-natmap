# luci-app-natmap（维护分支）

> 本仓库是 [uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（原作者，**已归档**）的维护分支。
> 在完全继承原作者设计、功能与 Apache-2.0 许可的前提下，针对新版 OpenWrt 与新版
> qBittorrent 做了一系列适配与新增功能。**感谢原作者** [uvswifft](https://github.com/uvswifft)
> 及上游 [EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)、
> [heiher/natmap](https://github.com/heiher/natmap) 的工作。

---

## ⚠️ 重要提示

1. **上游已归档**：原仓库 `uvswifft/openwrt-natmap` 已归档、停止维护。本仓库在其基础上继续适配，不保证与上游同步。
2. **打洞依赖网络条件**：作者弃坑的原因是大环境运营商大搞 NAT4、打洞基本失效。本插件**仅在公网 IP / NAT1（Full Cone）环境下有效**，请先确认你的宽带类型再使用。
3. **面向 OpenWrt 23.0+ / luci2 / golang>=1.20**：自 OpenWrt 23.0 之后使用 luci2 与新版 golang，旧版插件不兼容。本分支以 **OpenWrt 25.12.4** 为基准测试。
4. 本人不会编程，本次修改由 AI 完成，仅为个人使用。

---

## ✨ 本分支改动一览

相对原作者版本的主要修复与新增。

### 修复

| 项目 | 作用 |
|---|---|
| qBittorrent 端口联动 | 兼容 qBittorrent 4.3+ / 5.x（含 5.2.x）；密码含特殊字符也能登录并修改监听端口 |
| Transmission / Emby 联动 | 修复凭据含特殊字符时登录失败、状态码判断错误导致的无限重试 |
| Cloudflare 联动 | 修复 DDNS 永远更新失败、跳转规则更新被 API 拒绝的问题；记录不存在时给出明确提示，不再反复无效重试 |
| 防火墙 IPv6 放行 | 修复放行规则失效、开关判断写反、放行端口用错（用到 IPv4 目标端口）的问题——IPv6 入站不再被拒 |
| 接口绑定 | 修复与转发接口同时配置时覆盖 WAN 接口、导致打洞失效的问题 |
| 通知插件 | 消息含引号、换行、`&`、`=` 等不再发送失败；服务端返回错误时不再误报「发送成功」，并会自动重试 |
| 脚本健壮性 | 统一请求超时，避免网络卡死导致脚本挂起、进程堆积；避免并发写 uci/防火墙冲突；配置值含空格不再损坏环境变量 |
| 默认 STUN 服务器 | 由已停服的地址改为可用的 `stun.cloudflare.com`（仅影响新安装） |

### 新增

| 项目 | 作用 |
|---|---|
| 等待网络就绪后再打洞 | 开机 / 网络重置时先等 WAN 就绪再打洞，避免开机后一直打洞失败；等待有上限，超时照常启动，不会阻塞打洞 |
| 断网后可自恢复 | 长时间断网不再使实例永久停摆，网络恢复后自动重新打洞 |
| 端口同步到防火墙 | 打洞成功后自动把外部端口写入指定防火墙规则 |

### natmap 核心

使用官方最新 **20260214**（与 OpenWrt 25.12 官方 feed 同版本），相比旧版端口复用更稳定（减少端口跳变）、连接失败会自动重试、空闲转发保持更久。

---

## 🤖 手动编译与发布（GitHub Actions）

`.github/workflows/build.yml` 用 OpenWrt SDK 在 GitHub 上编译 apk 并可发布 Release，无需本地编译环境。

**触发方式：仅手动**

| 操作 | 行为 |
|---|---|
| Actions → Build & Release Packages → Run workflow | 编译当前分支代码；默认按仓库根目录 `Makefile` 的 `PKG_VERSION` 生成 `v<版本>` 标签并创建/更新对应 Release |
| 同上，`version` 填具体版本号 | 用指定版本号（不含 `v` 前缀）打标签、发版 |
| 同上，勾选 `force` | 即使标签已存在也重新编译，并覆盖 Release 资产 |

> 自动触发（推送 `v*` 标签、或 `master` 上 `PKG_VERSION` 变化时自动发版）已**关闭**——版本号改动不会再自动出包、自动建 tag。

**产物**（OpenWrt 25.12 / apk 格式）

| 文件 | 说明 |
|---|---|
| `luci-app-natmap-<版本>-r<revision>.apk` | 应用本体（界面、脚本、插件、默认配置） |
| `luci-i18n-natmap-zh-cn-<版本>.apk` | 简体中文翻译 |

均为 `PKGARCH:=all` 的架构无关包，任何架构的路由器都能安装。

> 翻译包版本号取自 LuCI feed（`PKG_PO_VERSION`），与应用的 `PKG_VERSION` 不同，属 LuCI 上游行为。

**实现要点**

- 用官方 `openwrt/gh-action-sdk` 在 `x86_64-25.12.5` SDK 容器里编译；SDK 版本写在 workflow 顶部的 `env.SDK_ARCH`，需要 ipk（OpenWrt 24.10 及更早）时改成 `x86_64-24.10.7` 并把收集产物时的 `.apk` 换成 `.ipk` 即可；
- 本仓库是**扁平布局**（`Makefile` 就在根目录），而 SDK 动作把 `/feed` 当作 feed 根目录、只识别它下面的一级子目录，因此 workflow 里用 `path: luci-app-natmap` 把代码签出到子目录，再把这个目录作为 feed 交给 SDK——这样 `feeds install` 与 `make package/luci-app-natmap/compile` 才能找到包；
- `luci-i18n-natmap-*` 翻译包由 `luci.mk` 在同一个目录下生成，编译本应用时一并产出（当前只保留 `po/zh_Hans`，因此只产出 `luci-i18n-natmap-zh-cn`）；
- `Makefile` 里把本应用与翻译包的 `DEFAULT` 显式设为 `m`——否则它们默认为 `n`，SDK 的 `make package/<目录>/compile` 会直接跳过未启用的包目录，构建不出任何东西；
- Release 说明由 `.github/scripts/release-notes.sh` 生成：列出上一个标签以来的提交、本次附加的文件与安装命令。

**关于包签名**：CI 编译的包未经 OpenWrt 官方密钥签名，安装时必须加 `--allow-untrusted`（见下文"直接安装预编译包"）。如需签名，在仓库 Secrets 里配置 `PRIVATE_KEY`（apk 签名私钥）即可，workflow 会自动带上。

---

## 📦 功能总览（继承自原版）

### 第三方服务联动（打洞成功后自动调用）

- **qBittorrent**：自动修改监听端口（已修复 5.2.x 兼容）
- **Transmission**：自动修改监听端口
- **Emby**：自动更新公网访问端口 / 连接地址
- **Cloudflare**：Origin Rules / Redirect Rules / DDNS（AAAA、HTTPS、SRV 记录）

### 消息通知

- Telegram Bot / PushPlus / Server酱 / Gotify

### 端口转发

- natmap 转发 / OpenWrt firewall DNAT 转发 / iKuai 端口映射

### 自定义脚本

- 打洞成功后执行自定义脚本（本分支的防火墙端口同步功能即基于此实现）

---

## 🚀 编译与安装

### 1. 放入 OpenWrt 源码

本仓库是**单包扁平布局**：仓库根目录就是包本体（`Makefile` + `htdocs` / `po` / `root`），因此不能用 `feeds.conf` 的 `src-git` 直接添加（feed 只识别根目录下的一级子目录）。请按包目录克隆进 OpenWrt 源码：

```sh
git clone https://github.com/hahaher123/luci-app-natmap.git package/luci-app-natmap
```

> 旧版（子目录布局）的 `src-git zzz https://github.com/hahaher123/openwrt-natmap.git` 写法已不再适用。

### 2. 编译

```sh
./scripts/feeds update -a
./scripts/feeds install -a
make menuconfig    # 勾选 Network → natmap / luci-app-natmap
make -j$(nproc)
```

> 建议编译固件时一并集成，而非事后安装插件。

### 3. 依赖

`luci-app-natmap` 依赖：`+natmap +jq +curl +openssl-util +bash`

### 4. 直接安装预编译包（apk，OpenWrt 25.12+）

不想自己编译时，可直接下载 [Releases](https://github.com/hahaher123/luci-app-natmap/releases) 里 CI 编译好的 apk：

```sh
# 包为自行编译、未经 OpenWrt 官方签名，必须加 --allow-untrusted
apk add --allow-untrusted ./luci-app-natmap-<版本>.apk

# 需要中文界面时再装翻译包（安装后自动切换到对应语言）
apk add --allow-untrusted ./luci-i18n-natmap-zh-cn-<版本>.apk

# 升级
apk add --allow-untrusted --upgrade ./luci-app-natmap-*.apk
```

> `jq`、`curl`、`openssl-util`、`bash` 来自 OpenWrt 官方源；`natmap` 本体本仓库不提供预编译包，请先按你现有的方式安装好，否则 `apk` 会因缺少依赖而拒绝安装。

---

## ⚙️ 配置说明

### 基本（LuCI → 服务 → NATMap）

| 配置项 | 说明 |
|---|---|
| `general_wan_interface` | WAN 接口名（如 `wan`） |
| `general_wait_network` | 是否等待网络就绪后再打洞（默认 `1`）。`0` = 不等待，直接启动（旧行为） |
| `general_wait_network_timeout` | 等待就绪的最长秒数（默认 `120`）。超时后照常启动 natmap，不会一直等下去 |
| `general_nat_protocol` | `tcp` / `udp` |
| `general_ip_address_family` | `ipv4` / `ipv6`（留空为双栈） |
| `general_interval` | keepalive 间隔（秒） |
| `general_stun_server` | STUN 服务器（默认 `stun.cloudflare.com`） |
| `general_http_server` | HTTP 打洞服务器（TCP 模式使用） |
| `general_bind_port` | 绑定端口（单端口或范围） |

### qBittorrent 联动

| 配置项 | 说明 |
|---|---|
| `link_enable` | 开启联动 `1` |
| `link_mode` | `qbittorrent` |
| `link_qb_web_url` | qB WebUI 地址 |
| `link_qb_username` / `link_qb_password` | qB 登录凭据 |
| `link_advanced_max_retries` / `link_advanced_sleep_time` | 重试次数与间隔 |

### 防火墙端口同步（本分支新增）

开启「自定义脚本」并指向本仓库内置脚本：

```sh
uci set natmap.@natmap[0].custom_script_enable=1
uci set natmap.@natmap[0].custom_script_path=/usr/share/natmap/plugin-link/firewall_nas.sh
uci commit natmap
/etc/init.d/natmap restart
```

脚本默认写入防火墙规则 `nas_incoming_5` 的 `dest_port`（目标 IPv6 为空，即放行整个局域网的目标端口）。如需调整，编辑 `/usr/share/natmap/plugin-link/firewall_nas.sh` 顶部的 `RULE_NAME` / `RULE_DEST_IP` / `SYNC_PROTO` 变量。

### Cloudflare Redirect Rules 联动（本分支修复）

入口域名需在 Cloudflare 开启代理（橙云）；跳转目标域名需为 DNS-only（灰云，解析到家宽公网 IP），否则 Cloudflare 无法代理非 80/443 端口。

| 配置项 | 说明 |
|---|---|
| `link_enable` | 开启联动 `1` |
| `link_mode` | `cloudflare_redirect_rule` |
| `link_cloudflare_redirect_rule_name` | 与控制台创建的规则名（description）一致 |
| `link_cloudflare_redirect_rule_target_url` | 跳转目标 URL，**端口位置**用 `NEW_PORT` 占位，如 `http://你的ddns域名:NEW_PORT/` |

跳转链路：`https://入口域名`（橙云）→ 302 → `http://ddns域名:打洞端口`（灰云直连）→ 路由器 DNAT → 内网服务。

---

## 📁 目录结构

仓库根目录即包本体：

```text
├── Makefile                                                 # 包定义
├── htdocs/luci-static/resources/view/natmap/natmap.js       # LuCI2 前端
├── po/                                                      # 多语言（en 英文原文 / zh_Hans 简体中文）
├── root/
│   ├── etc/config/natmap                                    # 默认配置模板
│   ├── etc/init.d/natmap                                    # procd 服务
│   └── usr/share/natmap/
│       ├── wait-network.sh                                  # 【新增】等待网络就绪 + 解析 -i
│       ├── update.sh                                        # 打洞成功回调入口
│       ├── link.sh / forward.sh / notify.sh
│       ├── plugin-forward/                                  # 转发插件
│       ├── plugin-link/
│       │   ├── qbittorrent.sh                               # 【已修复 5.2.x 兼容】
│       │   ├── transmission.sh / emby.sh / cloudflare_*.sh
│       │   └── firewall_nas.sh                              # 【新增】防火墙端口同步
│       └── plugin-notify/                                   # 通知插件（均已加固）
├── .github/
│   ├── workflows/build.yml                                  # 【新增】手动编译 + 发版
│   └── scripts/release-notes.sh                             # 【新增】生成 Release 说明
├── LICENSE
└── README.md
```

> - natmap 核心程序不在此仓库内，由 OpenWrt 官方 feed（`packages/net/natmap`）提供。
> - 更新 `po/` 里的翻译后，可用 `gettext` 命令从 `natmap.js` 重新提取文本。

---

## 🛠 常见问题

| 问题 | 排查 |
|---|---|
| 打洞失败 / 一直重试 | 确认宽带是公网 IP / NAT1；更换 STUN 服务器测试 |
| 开机后一直没有打洞 | 看日志是否停在「等待网络就绪」：说明 WAN 未就绪或 STUN 探测不通过（ICMP 被上游屏蔽时属误判），到 `general_wait_network_timeout` 后仍会照常启动；也可临时设 `general_wait_network=0` 排除探测影响 |
| qB 端口改不动 | 确认 `link_qb_web_url` 与 qB 实际地址一致；域名访问需加入 qB 域名白名单；日志看 `/var/log/natmap/natmap.log` |
| 防火墙规则未更新 | 确认 `custom_script_enable=1` 且脚本路径存在（`file` 校验要求文件真实存在） |
| 服务起不来 `validation failed` | `custom_script_path` 指向的文件必须存在 |
| Cloudflare 联动一直重试失败 | 确认规则名与 `link_cloudflare_redirect_rule_name` 一致；看日志 `修改失败: [...]` 中 Cloudflare 返回的具体 errors（新版脚本已输出）；规则需先在控制台创建 |
| Cloudflare DDNS 提示「未找到记录」 | 需先在 Cloudflare 控制台手动创建对应类型（AAAA/HTTPS/SRV 及 SRV 目标域名的 A 记录）的 DNS 记录，脚本只更新不创建 |
| IPv6 能连接但下载器无响应 | 确认对应下载器的「允许 IPv6」已开启，且 `link_qb_ipv6_address` / `link_tr_ipv6_address` 填写了下载器的 IPv6 地址 |
| `feeds install` 找不到本包 | 本仓库是扁平布局，不能用 `src-git` 添加；请按「编译与安装」第 1 步克隆到 `package/luci-app-natmap` |

---

## 📄 许可与致谢

- 本仓库继承原版许可：**Apache-2.0**（luci-app-natmap）与 **MIT**（natmap 核心）。
- 上游引用：
  1. [uvswifft/openwrt-natmap](https://github.com/uvswifft/openwrt-natmap)（原作者，已归档）
  2. [EkkoG/luci-app-natmap](https://github.com/EkkoG/luci-app-natmap)
  3. [EkkoG/openwrt-natmap](https://github.com/EkkoG/openwrt-natmap)
  4. [heiher/natmap](https://github.com/heiher/natmap)（natmap 核心程序）
