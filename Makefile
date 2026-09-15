# This is free software, licensed under the Apache License, Version 2.0

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-natmap
PKG_VERSION:=1.5.10
PKG_RELEASE:=1

LUCI_TITLE:=LuCI Support for natmap
LUCI_DEPENDS:=+natmap +jq +curl +openssl-util +bash

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Richard Yu <yurichard3839@gmail.com>

define Package/${PKG_NAME}/conffiles
/etc/config/natmap
endef

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
