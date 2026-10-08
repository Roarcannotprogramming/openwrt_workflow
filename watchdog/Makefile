include $(TOPDIR)/rules.mk

PKG_NAME:=cpe-watchdog
PKG_VERSION:=1.0.0
PKG_RELEASE:=3
PKG_LICENSE:=MIT

include $(INCLUDE_DIR)/package.mk

define Package/cpe-watchdog
  SECTION:=net
  CATEGORY:=Network
  TITLE:=HTTPS CPE recovery for Internet Detector
  PKGARCH:=all
  DEPENDS:=+internet-detector +luci-app-internet-detector +luci-i18n-internet-detector-zh-cn +curl +ca-bundle +python3
endef

define Package/cpe-watchdog/description
Configure HTTPS-only monitoring and recover the recognized CPE before rebooting
OpenWrt. Credentials are provisioned separately on the device.
endef

define Package/cpe-watchdog/conffiles
/etc/config/cpe-watchdog
endef

define Build/Compile
endef

define Package/cpe-watchdog/install
	$(INSTALL_DIR) $(1)/etc/config $(1)/etc/uci-defaults $(1)/lib/upgrade/keep.d
	$(INSTALL_DIR) $(1)/usr/lib/cpe-watchdog $(1)/usr/share/cpe-watchdog
	$(INSTALL_CONF) ./overlay/etc/config/cpe-watchdog $(1)/etc/config/cpe-watchdog
	$(INSTALL_BIN) ./overlay/etc/uci-defaults/95-cpe-watchdog $(1)/etc/uci-defaults/
	$(INSTALL_DATA) ./overlay/lib/upgrade/keep.d/cpe-watchdog $(1)/lib/upgrade/keep.d/
	$(INSTALL_DATA) ./overlay/usr/lib/cpe-watchdog/*.py $(1)/usr/lib/cpe-watchdog/
	$(INSTALL_DATA) ./overlay/usr/share/cpe-watchdog/internet-detector.conf $(1)/usr/share/cpe-watchdog/
	$(INSTALL_DATA) ./overlay/usr/share/cpe-watchdog/down-script.internet $(1)/usr/share/cpe-watchdog/
endef

$(eval $(call BuildPackage,cpe-watchdog))
