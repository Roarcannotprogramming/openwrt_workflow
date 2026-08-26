# luci-app-uuplugin

uuplugin（UU 加速器 / PassWall 共存层）的 LuCI 界面。范围有意收窄为
**配置 + 只读状态面板**：界面只读写 `/etc/config/uuplugin`，不含任何
fw4 reload / firewall restart / 手动回滚按钮——危险动作全部留在
uuplugin 服务与 guard 的既有路径里（保存并应用 → procd reload trigger）。

现代 JS 形态（`htdocs/luci-static/resources/view/` + menu.d/acl.d JSON），
零 luci-compat 依赖，OpenWrt 23.05 → master 原生可用。

```
htdocs/luci-static/resources/view/uuplugin/
├── overview.js    只读状态面板（每 5 秒轮询，全数据源带降级值）
└── config.js      form.Map 配置表单（main 段 + device 匿名段列表）
root/usr/share/luci/menu.d/luci-app-uuplugin.json    菜单（服务 → UU 加速器）
root/usr/share/rpcd/acl.d/luci-app-uuplugin.json     rpcd ACL
po/                templates/uuplugin.pot + zh_Hans/uuplugin.po
```

## ACL 粒度的两条事实（JSON 不许注释，写在这里）

1. **rpcd 的 uci ACL 只有整 config 粒度。** 状态面板要读 `firewall`
   （uu zone / 转发三段）与 `passwall`（绕行 ACL 段），于是 read 里带上
   这两个整 config——`read passwall` 意味着凡被授予 `luci-app-uuplugin`
   这个 ACL 组的账户能读到 passwall 全部配置，**含代理凭据**。默认 root
   会话本来就全能，此事实只与"把该组授给受限账户"的部署者有关。
2. **状态面板全程无 exec 权限，这是有意的。** 防火墙行读的是配置层
   （uci firewall），刻意不查内核 nft——那需要 exec；配置层在不在 + 下一行
   的未验证标记（`firewall.unproven`）合起来，语义反而比查内核更准。

`file` 路径项授 `"read", "list"` 双权限，原因：master rpcd 对
`file stat` 校验的是路径的 `list` 权限（file.c 的 `rpc_file_stat` →
`rpc_check_path(msg, R, "list", ...)`），而老版本 rpcd 的该权限字符串
未逐版本核实——双授跨版本稳妥。这两个文件是 0 字节空标记，`read`
不会泄露任何内容。方法级的 `file: [ "stat" ]` 仍由本组授；如此本组
ACL 自足，不依赖 luci-base 的 `/`、`/*` 通配 `list` 兜底。

## 状态面板的数据源（全部只读）

| 行 | 来源 |
|---|---|
| 服务运行 | `ubus service list {"name":"uuplugin"}` 实例 running/pid |
| 开机自启 | `ubus rc list {"name":"uuplugin"}` 的 enabled（guard 第 3 级 disable 在这里暴露） |
| 加速隧道 | `ubus network.device status` 中 `^tun` 设备及 up 状态 |
| 防火墙三段 | uci firewall：`uu`(zone) / `lan_uu` / `uu_lan`(forwarding)，配置层 |
| 未验证标记 | `fs.stat /etc/uuplugin/firewall.unproven` |
| guard 布防 | `fs.stat /etc/uuplugin/checkpoint/.active` |
| PassWall 联动 | uci passwall：匿名 acl_rule 段按 `remarks='uuplugin'` 锚定（与 render 一致，排除历史命名段） |
| 最近日志 | `ubus log read {"lines":300,"stream":false}`，客户端过滤含 uuplugin 的行，取末 20 行 |

## 设备列表与实现侧的对齐

- device 段匿名（`service uuplugin add` / autoadd 建的就是匿名段）；
- MAC 落盘前强制小写，与 cmd_add 的 `tr 'A-F' 'a-f'` 归一一致，
  否则 scan 的小写去重会闪过大写重复项。

## 中文界面

luci.mk 自动派生翻译包：zh_Hans 经 `LUCI_LC_ALIAS.zh_Hans=zh-cn` 映射，
包名 **luci-i18n-uuplugin-zh-cn**，CI/编译侧需与本包一并选中。msgid
一律英文（LuCI 惯例，菜单三个标题同样是英文 msgid），中文全部在
`po/zh_Hans/uuplugin.po`；未装翻译包时整个界面（含菜单）回退英文。
