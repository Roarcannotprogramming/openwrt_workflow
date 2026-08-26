# uuplugin —— UU 加速器集成层（我们全部的实现都在这一个包里）
#
# 组成：
#   * /etc/config/uuplugin       设备列表与开关（动态配置的唯一入口）
#   * init                       服务 + 设备发现入口（service uuplugin scan/add/...）
#   * /usr/libexec/uuplugin/     内部脚本：render（UCI→PassWall ACL）、scan、
#                                guard（死人开关：验证式回滚 + 出网自检）
#   * /usr/share/uuplugin/       判定用的特征表：nintendo-oui、hostname-hints
#   * uci-defaults               fw4 zone "uu"（device tun*）+ lan↔uu 转发
#
# 依赖模型：本包是"UU 加速器 + PassWall 共存"的集成层，存在意义就系于
# 两者，因此同时硬依赖 uuplugin-bin（本体）与 luci-app-passwall——
# 装包即保证环境完整，渲染脚本把配置缺失当异常而不是可选路径。

include $(TOPDIR)/rules.mk

PKG_NAME:=uuplugin
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/uuplugin
  SECTION:=net
  CATEGORY:=Network
  TITLE:=UU accelerator / PassWall coexistence integration
  URL:=https://uu.163.com/
  DEPENDS:=+uuplugin-bin +luci-app-passwall
endef

define Package/uuplugin/description
  Integration layer making the NetEase UU accelerator and PassWall coexist:
  UCI-configured device list rendered into a PassWall "no-proxy" ACL, LAN
  console discovery (service uuplugin scan/watch/add), and an fw4 zone
  (device tun*) via uci-defaults. Depends on both sides by design.
endef

# 两张特征表都明说了"可以自己加行"，那就必须当配置对待——否则升级一次
# 包，INSTALL_DATA 直接把用户加的规则盖掉，而且不留痕迹
define Package/uuplugin/conffiles
/etc/config/uuplugin
/usr/share/uuplugin/nintendo-oui
/usr/share/uuplugin/hostname-hints
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/uuplugin/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/uuplugin.init $(1)/etc/init.d/uuplugin
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/uuplugin.config $(1)/etc/config/uuplugin
	$(INSTALL_DIR) $(1)/usr/libexec/uuplugin
	$(INSTALL_BIN) ./files/uuplugin-render $(1)/usr/libexec/uuplugin/render
	$(INSTALL_BIN) ./files/uuplugin-scan $(1)/usr/libexec/uuplugin/scan
	$(INSTALL_BIN) ./files/uuplugin-guard $(1)/usr/libexec/uuplugin/guard
	$(INSTALL_DIR) $(1)/usr/share/uuplugin
	$(INSTALL_DATA) ./files/nintendo-oui $(1)/usr/share/uuplugin/nintendo-oui
	$(INSTALL_DATA) ./files/hostname-hints $(1)/usr/share/uuplugin/hostname-hints
	$(INSTALL_DIR) $(1)/etc/uci-defaults
	$(INSTALL_BIN) ./files/uuplugin.defaults $(1)/etc/uci-defaults/50-uuplugin
endef

$(eval $(call BuildPackage,uuplugin))
