# luci-app-uuplugin —— UU 加速器（uuplugin）的 LuCI 界面
#
# 范围（有意收窄）：配置表单 + 只读状态面板。界面不含任何 fw4 reload /
# firewall restart / 手动回滚入口——危险动作全部留在 uuplugin 服务与
# guard 的既有路径里，UI 只读写 /etc/config/uuplugin。
#
# 形态：现代 JS 视图（htdocs/luci-static/resources/view/ + menu.d/acl.d
# JSON），零 luci-compat 依赖，OpenWrt 23.05 → master 原生可用。
#
# 中文界面：luci.mk 按 po/ 目录自动派生翻译包；zh_Hans 经
# LUCI_LC_ALIAS.zh_Hans=zh-cn 映射，派生包名为 luci-i18n-uuplugin-zh-cn。
# CI/编译侧需把它与本包一并选中，界面才显示中文（未装翻译包时整个界面
# 含菜单回退英文 msgid）。
#
# PKG_LICENSE 刻意不声明：与 package/uuplugin 的 Makefile 保持一致（那里
# 同样未声明）。日后若补充，请两处一起补。

include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for uuplugin (NetEase UU accelerator)
LUCI_DEPENDS:=+uuplugin
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
