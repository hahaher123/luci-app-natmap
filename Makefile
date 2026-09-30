# This is free software, licensed under the Apache License, Version 2.0

include $(TOPDIR)/rules.mk

# 版本号：主版本故意取高位，用来压过官方 feed 里的同名包。
#
# 官方 openwrt/luci 的 applications/luci-app-natmap 与本仓库同名，而它**不在自己的
# Makefile 里写版本号**，走 luci.mk 的默认值：PKG_VERSION 为空时落到 PKG_SRC_VERSION，
# 即 findrev 推导出的 `YY.DDD.SSSSS~hash`（实测 25.12.5 的 x86_64 feed 里是
# 26.270.72870~a24d1f2）。apk 与 opkg 都按「版本号高者胜」解析，本包若低于官方，
# 一次 apk upgrade 就会被官方版本顶掉、本仓库的改动全部丢失（两者还争同一个
# /etc/init.d/natmap 与 /etc/config/natmap）。主版本取 40 > 官方首段的年份 26，
# 可长期压过；PKG_VERSION 一变更，PKG_RELEASE 按约定复位为 1。
PKG_NAME:=luci-app-natmap
PKG_VERSION:=40.0.2
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for natmap
LUCI_DEPENDS:=+natmap +jq +curl +openssl-util +bash

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Richard Yu <yurichard3839@gmail.com>

define Package/${PKG_NAME}/conffiles
/etc/config/natmap
endef

# ACL 里每个 /var/... 授权都必须同时写一份 /tmp/... 对应项。
#
# rpcd 自 e37ed9d8（GHSA-q5gr-86pq-vvwr「file: re-authorize ACL against resolved
# path to close symlink bypass」）起，会对 file.read / file.write / file.stat /
# file.list / file.md5 用 realpath() 解析后的路径**再跑一遍** ACL 检查。OpenWrt
# 上 /var 是指向 /tmp 的符号链接，于是 ACL 里的 /var/run/natmap/* 在解析后变成
# /tmp/run/natmap/*；只授权前者，第二次检查就 EACCES。
#
# 后果最容易被误判：LuCI 的 fs.read() 用 .catch() 静默吞掉错误，页面表现为
# 「外部 ip / 端口」与「执行日志」永远为空（日志文件其实是好的、打洞也是成功的），
# 而「运行状态」走 ubus service list、不经过 file ACL，所以**只有它是对的** ——
# 看着像 natmap 没工作，其实是没读到。官方 luci-app-banip（12b22606）、
# luci-app-adblock（7b4b303d）都是同一个坑，修法相同。
#
# 保留 /var 项是必要的：/var 是真实目录的目标（CONFIG_TARGET_ROOTFS_PERSIST_VAR
# 等）上只有它才有效。改 ACL 时别把任何一边删掉。
# reports/luci-app-natmap-ipv6-allow/harness.py 有用例守着这条不变量。
#
# 翻译包（luci-i18n-natmap-*）的版本号。
#
# luci.mk 默认用 PKG_PO_VERSION 给翻译包定版，它由「最后一次改动 po/ 的提交」推导而来
# （形如 26.258.10506~e205b93，见 luci.mk 里的 findrev），与 PKG_VERSION/PKG_RELEASE 无关，
# 结果是翻译包文件名和应用包对不上，用户按 Release 说明也拼不出来。
# luci.mk 中该变量声明为 `PKG_PO_VERSION?=`（可被覆盖），这里显式钉成与应用包同一版本，
# 使翻译包同样产出 luci-i18n-natmap-zh-cn-<PKG_VERSION>-r<PKG_RELEASE>.apk。
PKG_PO_VERSION:=$(PKG_VERSION)-r$(PKG_RELEASE)

include $(TOPDIR)/feeds/luci/luci.mk

# 默认选中本应用及其全部翻译包。
#
# 原因：luci.mk 生成的翻译包默认值是 `LUCI_LANG_<lang>||(ALL&&m)`，本应用自身的默认值
# 也是空的 —— 在没有 menuconfig 勾选的情况下它们都是 n。而 SDK 的
# `make package/<dir>/compile` 只会编译「在 .config 中已启用」的子目录，未启用的会被
# 直接跳过（CI 里表现为一个包都构建不出来）。这里统一显式改成 m，
# 使 `make defconfig` + `make package/luci-app-natmap/compile` 稳定产出
# luci-app-natmap 与 luci-i18n-natmap-*。这不影响依赖与运行时行为，
# 用不上的用户仍可在 menuconfig 里取消勾选。
$(eval Package/$(PKG_NAME)/DEFAULT:=m)
$(foreach pkg,$(filter luci-i18n-$(LUCI_BASENAME)-%,$(LUCI_BUILD_PACKAGES)),$(eval Package/$(pkg)/DEFAULT:=m))

# call BuildPackage - OpenWrt buildroot signature
