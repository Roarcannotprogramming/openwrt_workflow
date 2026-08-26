# uuplugin-bin —— 网易 UU 加速器本体（在线取包器）
#
# 为什么不在构建期下载并固化二进制：
#   1. 上游只保留"当前版"——旧版本 URL 会 404（已实测 v14.2.1/v13.5.1），
#      锁版本+哈希的构建会在网易转版本的瞬间失效；
#   2. 插件运行期本来就会被 App 触发自升级，构建期确定性无从谈起；
#   3. 不把网易的专有二进制重新分发进我们的产物，法律上也更干净。
#
# 因此本包只携带 uu-fetch：首次启动（或手动）时按官方 API 取"当前版"，
# 完整性用同一 API（https）返回的 md5 校验。版本演进完全跟随上游。

include $(TOPDIR)/rules.mk

PKG_NAME:=uuplugin-bin
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/uuplugin-bin
  SECTION:=net
  CATEGORY:=Network
  TITLE:=NetEase UU accelerator runtime (online fetcher)
  URL:=https://uu.163.com/
  DEPENDS:=+kmod-tun +iptables-nft
endef

define Package/uuplugin-bin/description
  Fetches the current NetEase UU accelerator plugin binaries from the
  official API into /usr/sbin/uu at first service start (or manually via
  uu-fetch). No upstream bits are vendored at build time: upstream only
  serves the latest version and the plugin self-updates at runtime anyway.
endef

define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/uuplugin-bin/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) ./files/uu-fetch $(1)/usr/sbin/uu-fetch
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/uuplugin-bin.upgrade $(1)/lib/upgrade/keep.d/uuplugin-bin
endef

# 卸载包 = 卸载 UU 本体：uu-fetch 在运行期落下的程序文件一并清掉，
# 只保留 .uuplugin_uuid / .sn 身份文件（重装免去手机 App 重绑）。
# 要连身份一起清除：rm -rf /usr/sbin/uu
define Package/uuplugin-bin/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0
rm -f /usr/sbin/uu/uuplugin /usr/sbin/uu/xuplugin-guardian \
	/usr/sbin/uu/xtables-nft-multi /usr/sbin/uu/uu.conf
exit 0
endef

$(eval $(call BuildPackage,uuplugin-bin))
