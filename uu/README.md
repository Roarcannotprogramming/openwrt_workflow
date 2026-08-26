# uu-openwrt

网易 UU 加速器的 OpenWrt 原生封装，目标场景：让指定游戏机（NS2 等）
走 UU 加速；若路由器上恰好跑着 PassWall，同时让它们绕过 PassWall。
可直接进编译树。

数据通路的完整拓扑（表/链/priority/规则文本/包旅程）见
**[docs/datapath.md](docs/datapath.md)**。

## 结构与边界

```
package/
├── uuplugin-bin/            # 网易本体（在线取包器 uu-fetch + keep.d 身份保留）
└── uuplugin/                # 我们全部的实现，DEPENDS +uuplugin-bin
    ├── Makefile
    ├── files/
    │   ├── uuplugin.init    # 唯一的用户入口：服务 + 设备发现命令
    │   ├── uuplugin.config  # /etc/config/uuplugin（动态配置的唯一入口）
    │   ├── uuplugin-render  # → /usr/libexec/uuplugin/render（内部脚本）
    │   ├── uuplugin-scan    # → /usr/libexec/uuplugin/scan（内部脚本）
    │   ├── uuplugin-guard   # → /usr/libexec/uuplugin/guard（死人开关）
    │   ├── nintendo-oui     # 任天堂 OUI 数据（conffiles，可自行追加）
    │   ├── hostname-hints   # 主机名正则表（conffiles，可自行追加）
    │   └── uuplugin.defaults# uci-defaults：fw4 zone "uu"(device tun*) + 转发
    └── tests/               # 假 uci 逻辑测试，359 项断言，macOS/Linux 可跑
```

判定游戏机用的两张特征表是**数据文件**，不是代码：想加自家设备直接往
`/usr/share/uuplugin/{nintendo-oui,hostname-hints}` 追加一行即可，不用改
脚本、不用重装包。两者都登记为 `conffiles`，升级包不会覆盖你的改动
（代价是新版规则也不会自动进来）。

测试套件本身用变异测试验过：把每一处实现逐个改回坏写法，确认套件真的会红。
最近一轮 18 个变异体，15 个被抓住，3 个存活且都查清了原因——两个改不出可观测
差异（`umask 077`→`022`：状态目录被紧随其后的 `chmod 0700` 拉回原样，只剩那个
空标记文件从 0600 变成 0644，而它躺在 0700 的目录里、内容为空，既读不到也没什
么可读；先删转发后删 zone：两句都在同一次 `uci commit` 之前，`commit` 是拿合并
后的整体状态重渲染整个文件，落盘逐字节相同，次序只在"进程死在两句之间、半截
delta 留在 `/tmp/.uci` 里"时才有意义，而那条路径沙箱表达不了），一个是我自己设
计失败的死变异（掺进 `nx` 的字母哨兵被 `(^|[^a-z0-9])nx([^a-z0-9]|$)` 的边界卡
掉，而数字哨兵本就一条真规则都撞不上，那道与门根本推不开；它想验的性质由"两串
齐中改成任一命中"那个变异体覆盖着，6 条红）。
另有 2 个真漏洞当场补上：`passwall_wait` 的默认值 20 没人钉住（改成 99 照样
全绿），guard 状态目录的默认路径三处各写各的、漂了也没人比对。

比"跑绿"更值得记的是**变异测试自己会骗人**，这轮两种都撞上了：

- **畸形变异体**：夹具的替换串少留一个换行，把变异体和下一行粘成一句，`umask`
  拿到多余参数报错、`&&` 短路，于是两条红看着像"抓住了"，其实抓的是夹具自己的
  bug。现在打完补丁先 `sh -n`，语法不过的变异体一律判废，不许算成绩。
- **抖动的断言**：死人开关那场（延时校验自己醒来回滚）与前面几场共用锁和检查点
  路径——先醒的把检查点 `mv` 走，后醒的看见 `.active` 没了就直接退，两条断言于是
  无缘无故地红；而夹具会把这两条红读成"这个变异被抓住了"。假阴性方向恰好是最
  危险的那侧。现在那场用私有的锁 + 私有的状态目录，路径层面隔离，不靠时序运气。

依赖模型（`uuplugin` 是"UU + PassWall 共存"的集成层，存在意义就系于两者，
因此同时硬依赖）：

```
uuplugin ──DEPENDS──> uuplugin-bin        （网易本体，在线获取）
    └────DEPENDS──> luci-app-passwall     （PassWall，第三方 feed）
```

- **uuplugin-bin**：本体不在构建期固化——上游只保留"当前版"（旧版本 URL
  实测 404），且插件运行期会自升级；`uu-fetch` 在首次服务启动时按官方 API
  （https，md5 同源校验）取当前版。构建产物不含网易 bits。
- **luci-app-passwall**：安装由包管理器保证，`/etc/config/passwall` 缺失
  按异常报错。"装了但没在运行"是正常态：render 只落配置等它下次启动自取，
  在运行且变更有运行时效果才重启它。

## 使用：一个配置文件 + service 命令

```sh
service uuplugin scan             # 被动清单：租约+ARP，标记任天堂 OUI/主机名特征
service uuplugin sweep            # 主动扫描：ping 扫整个 lan 网段，把沉默设备逼出 ARP 表
service uuplugin watch [秒]       # 差分识别：让 NS2 重连 Wi-Fi，新出现的就是它
                                  #（与厂商无关，OUI 未收录的新硬件/随机 MAC 也适用）
service uuplugin add <mac> [名字] # 手动加入（人工填写入口，始终保留）
```

`scan` 读的租约不是单个文件而是一张候选表：UCI 里每个 dnsmasq 的
`leasefile`，并上三条常规路径（`/tmp/dhcp.leases`、
`/var/lib/misc/dnsmasq.leases`、`/tmp/var/lib/misc/dnsmasq.leases`），存在
的全读、按 MAC 去重（先读到的赢）。只收 dnsmasq 一家：odhcpd 与 ISC dhcpd
的落盘格式不同，喂进解析只会产出垃圾行。注意网易本体二进制找租约用的是它
自己内置的路径清单，UCI 把 leasefile 指到别处时 App 侧设备列表可能缺人——
那是二进制的局限，不归本包管。

`sweep` 的网段是向 netifd 问 `lan`（接口逻辑名，可由
`uuplugin.main.lan_iface` 覆盖）要来的（`network_get_subnet`），不假设
`/24`——`/23`、`/25`、`/26` 都按真实前缀长度枚举，且会先把接口地址掩成
网络地址（netifd 给的是 `192.168.7.1/23` 这样的接口地址，直接拿前三段当
基址会漏掉半个网段）。默认最多扫 510 个地址（一个 `/23`）：再大不只是费
时间，扫描会给每个不存在的地址留一条 FAILED 邻居表项，而内核默认
`gc_thresh3=1024`，贴着扫等于自己把 ARP 表顶穿。超限时明说扫不动并给出
`UU_SWEEP_MAX=<确切数字>` 的抬法，**绝不偷偷只扫前 254 个**——静默的部分
结果比没有结果更误导人。大网段请改用 `watch` 差分识别（与网段大小无关）。

自动模式（init 在每次 start/reload 时执行）：

```
config uuplugin 'main'
	option autodetect '1'   # 发现候选设备 → logread 提示（默认开）
	option autoadd '0'      # 命中任天堂 OUI 直接加入（默认关——加入=改变
	                        # 流量路径，需明确授权）
```

设备列表本体在 `/etc/config/uuplugin` 的 `device` 段，LuCI/uci 直接编辑同样
有效：`uci commit uuplugin && /etc/init.d/uuplugin reload`。
reload 只重渲染，不打断正在加速的会话。

## 每个时刻做什么

| 事件 | 响应者 | 动作 |
|---|---|---|
| 编译 | buildroot | 两个包都不含网易 bits，纯打包自有文件 |
| 镜像首次开机 | uci-defaults | 找出纳管 `lan` 的 fw4 zone，写 zone `uu` + 双向转发，自删；找不到则一个字都不写并保留脚本下次开机重试；写入成功后留下未验证标记（`/etc/uuplugin/firewall.unproven`），交由 guard 兜底 |
| 服务启动 | procd → init | 本体缺失则 uu-fetch → render → ensure_firewall（受保护的 fw4 reload，或短路路径补一次自检；证明为好才撤未验证标记）→ scan auto → 拉起二进制 |
| 配置变更 | procd reload trigger | 重渲染；实例参数没变则隧道进程不动 |
| tun 出现/消失 | fw4 的 `tun*` 通配（包到达时匹配） | 零代码 |
| PassWall 重启 | 它重放自己 config 里的 ACL | 零代码 |
| 二进制崩溃 | procd respawn | 零代码 |
| sysupgrade | keep.d + conffiles | 绑定身份、`/etc/config/uuplugin`、两张特征表、guard 状态目录（`/etc/uuplugin`：检查点 + 未验证标记）都在 `-c` 的保留范围内；本体重新在线获取 |

没有自研 daemon；唯一长驻进程是网易二进制本身（fw4、PassWall 同样如此）。

### uci-defaults 怎么找 LAN 侧 zone

转发两端的 LAN 侧 zone 名不写死：`lan` 只是默认配置的叫法，改名（`home`/
`trust`）和一个 zone 纳管多个 network 都很常见。按 fw4 的真实归属规则找：

- zone 的 `network` 列表里列了 `lan`；或
- `network.lan` 用 `option zone` 反向指到该 zone——fw4 的 `parse_zone` 会把
  ubus 里 `zone` 字段等于本 zone 名的接口并进来（`related_ubus_networks`）。

fw4 **没有**"zone 省略 `network` 就拿 zone 名当 network 名"这条规则，那是
fw3 的语义；按它写会挑中一个 fw4 其实不往里归任何流量的 zone。

找不到就什么都不写、`exit 1` 报错退出。原因值得写下来：fw4 对解析不到的
zone 名（`parse_zone_ref` 返回 null）只是 `warn_section` 一句、`return` 跳过
**这一条 forwarding**，ruleset 照常下发、`forward_uu` 链照常建（每个 zone
都有）、`fw4 check`（只是 `nft -c -f -` 语法检查）照常通过——于是"加速全程
不通"会被每一处自检报成绿色。宁可留着脚本下次开机重试，也不写一条已知指
向空处的规则。`logread -e uuplugin` 会告诉你发生了什么。

## 回滚保障（guard，设计进产品的死人开关）

所有可能断网的动作（fw4 reload / PassWall 重启 / 拉起闭源二进制）都经
`/usr/libexec/uuplugin/guard` 按同一模式执行：`protect`（备份配置 + 记录
变更前网络状态 + 派生脱离会话的延时校验）→ 动作 → 验证 + `commit`；
失败或调用方死在半路 → **验证式回滚**：

1. 先还原配置文件——此后任何时刻掉电/重启，持久状态都是已知良好检查点；
   - **第 1.5 级**：拆掉**未经验证**的 `uu` zone 与两条 `lan↔uu` 转发（仅当
     `/etc/uuplugin/firewall.unproven` 在）：`uci delete` + `commit firewall`，
     然后置 `did_fw=1` 逼出下一级的 `fw4 reload`——否则配置干净了而内核里那份
     ruleset 照旧。检查点覆盖不到这三段，原因见本节末；
2. `fw4 reload`，失败升级 `firewall restart`；
3. 停用 uuplugin（回滚场景保持安全优先于保持功能）；
4. 出网自检重试 3 次，通过才算回滚成功；
5. 仍失败且**变更前网络本来正常**才动用最后手段：延时重启路由器
   （配置已是检查点状态，重启即按已知良好配置重建；`guard_reboot=0` 可关）。
   变更前就断网的不重启，防止把上游故障误判为自己的锅。**没有检查点可查
   的（`watch` 路径）同样不重启**——手上没有"变更前网络是好的"这个证据，
   就不该为一次上游抖动把管理通道自己掐掉。

检查点落在 `/etc/uuplugin`（0700）：`/var` 在 OpenWrt 上是指向 `/tmp` 的
软链，把"兜底之底"放进内存盘等于没有兜底；选 `/etc` 而不是同样持久的
`/root`，是因为 `sysupgrade -c` 的保留清单就是 `SAVE_OVERLAY_PATH=/etc`
——而"刚升完级"恰恰是最需要它的时刻。

重启 PassWall 之后"表回来了没"是**有截止时间的轮询**，不是定长等待。原先写死
`sleep 3`：x86 上够，MT7621 那类 mipsel 上不够——PassWall 重启要停
sing-box/chinadns-ng、flush 掉整张 `inet passwall` 表、重跑 nftables.sh 重建链、
再把 chnroute/gfwlist 几万条元素灌回 nft set，光最后一步就常常超过 3 秒。于是慢
设备上**每次改设备列表都被判成重启失败**而走进回滚：ACL 白写、PassWall 挨第二次
重启、uuplugin 被停用且 `disable`（重启也不会自己回来）——用户视角只是
`service uuplugin add` 报了个失败，然后设备再也不加速。上限由
`uuplugin.main.passwall_wait` 控制（默认 20 秒，可抬到 60）；是**上限不是等待**，
表一回来立刻往下走，快设备照样两三秒收工，调大不会让正常情况变慢。值写成非数字
会回落到默认值并按 `warn` 记一条日志——绝不静默架空成"一秒都不等"（`[ -lt ]`
拿到非数字报错退出 2，而 `while`/`if` 把"报错"读成"条件不成立"，这正是
`UU_SWEEP_MAX` 那段注释讲过的坑）。

轮询分两段：**先等旧表消失，再等新表回来**。因为 `restart` = stop + start，若
stop 把拆表甩给后台，`restart` 刚返回时看到的可能是还没拆掉的旧表——"PassWall
其实已经死了"于是被读成"重启成功"，commit、清检查点、死人开关解除，而代理已经
躺下。原来那句 `sleep 3` 是顺手挡住了这一幕，改成轮询后必须显式保留。第一段窗口
就取 3 秒（老代码那个窗口，一秒不多），**等不到也继续**——stop 可能同步且极快，
我们压根没赶上那一瞬空窗，把"没看到空窗"当失败会让每次快速重启都被误判。

自检用 ICMP + HTTP 双探针（防 ICMP 限流误判）。有效性证据：沙箱单测
（含回滚往返、重启门控双向、无检查点不重启、显式检查点路径、调用方死亡
自动回滚、未验证段的拆除（检查点被污染 / 无检查点 / commit 落不了盘三种
路径）、标记生命周期（写入→拆除→撤销）、PassWall 重启轮询的两段窗口与
超时回滚），加真机两类实弹演练——真实配置偏移的 restore 往返、黑洞探针
触发的死人开关全链路。

### 检查点管不到的那一段：`firewall.unproven`

上面第 1 级"还原配置文件"有个前提：被改动的东西，在改动之前进过检查点。
`uu` zone 与两条 `lan↔uu` 转发恰恰不满足这个前提——它们是 **uci-defaults 在
装包时**就 `commit` 进 `/etc/config/firewall` 的，而让它们生效的 `fw4 reload`
要等到后来 `/etc/init.d/uuplugin start` 里的 `ensure_firewall` 才发生。也就是
说，`protect` 取检查点的那一刻，这三段**已经躺在备份里**了。

于是 reload 后断网走出来的是这么一条链：`cmp -s` 判定检查点与当前配置逐字节
相同 → `did_fw=0`、配置一个字节不改 → 第 2 级 `if [ "$did_fw" -eq 1 ]` 不成立、
**连 `fw4 reload` 都不做**，内核里那份有害 ruleset 原样留着 → 停用 uuplugin
也拿不掉活在配置文件里的 zone → 自检失败 → 重启路由器 → fw4 从同一份配置
重新渲染出同样的 ruleset，而 uuplugin 已 `disable`、guard 不再布防：**问题
原样回来，且再没有兜底了**。镜像首次开机更彻底——uci-defaults 先跑、
`/etc/init.d/firewall start` 直接把三段渲染进内核，等 uuplugin 起来时
`ensure_firewall` 在 `nft list chain inet fw4 forward_uu` 那一行就短路返回，
整条路径上**从来没有过任何检查点**。

修法不是去补检查点的内容，而是让回滚**有能力拆掉这三段**。授权载体是一个
空标记文件 `/etc/uuplugin/firewall.unproven`，含义是"这三段进了持久配置，
但还没有任何人验证过它无害"：

| 谁 | 什么时候 | 做什么 |
|---|---|---|
| `uuplugin.defaults` | 三段写入并通过写后验收之后 | 建标记（早退路径——已装好、包升级重跑——不建：那不是新写入） |
| `guard restore` | 每次回滚，第 1 级之后、第 2 级之前 | 标记在 → `uci delete` 掉三段 + `commit` + 置 `did_fw=1`（逼出第 2 级的 reload）+ 删标记 + `log crit`；`commit` 落不了盘则保留标记待下次回滚重试，日志照实说失败、不打"已拆除" |
| `uuplugin.init` 的 `ensure_firewall` | `fw4 reload` 后自检通过；或短路路径上补做的自检通过 | 删标记（撤掉安全网） |

三处细节值得记下来，改的时候别绕过去：

- **拆段这一级刻意不在 `[ -f "$CKPT/.active" ]` 块里面。** `watch` 路径与镜像
  首次开机路径根本没有检查点，可祸首照样可能是这三段——没有检查点不等于
  没有嫌疑人，那种情形下这一级是唯一还能动持久配置的手。
- **刻意排在"还原配置文件"之后。** 先把检查点内容盖回文件、再从盖回来的内容
  里删段，"检查点被污染（备份里就带着这三段）"与"检查点干净"两种情形才收敛到
  同一结果；反过来先删后盖，删掉的会被检查点原样盖回来，等于没删。
- **撤销标记只能由 `ensure_firewall` 做，绝不能塞进 `guard commit`。**
  `start_service` 是先 `render` 后 `ensure_firewall`，而 `render` 成功重启
  PassWall 时同样会调一次 `guard commit`——那会儿 `fw4 reload` 还没发生，
  标记会被提前清掉，整套兜底当场作废且不留一个字的痕迹。

`ensure_firewall` 的三条出口一律按同一条规矩走：**证明为好才删标记，其余一律
留着**。reload 成功且自检通过 → 删；短路路径（fw4 启动时就渲染好了）补做一次
出网自检，通过才删、不通过留着；`fw4 check` 不过、reload 后链没出来、连
`uu` zone 都不在——一律不删，回滚全指着它才敢动那三段。短路路径上标记不在就
一个探针都不发：wan 每抖一次就 reload 一次 uuplugin，白探一遍 ICMP+HTTP
要把 init 挂住十几秒。

## 进编译

`package/` 拷进 buildroot（或做 feed），选中 `CONFIG_PACKAGE_uuplugin=y`，
`uuplugin-bin` 与 `luci-app-passwall` 随依赖带入（构建树需已加 passwall
feed）。我们的两个包都无下载步骤，构建永不因上游变动而断。

## 现网改装（不重刷固件）

红线：每个可能影响连通性的动作前停下 review。

```sh
apk add --allow-untrusted uuplugin-bin-*.apk uuplugin-*.apk
# ↑ 落盘 + uci-defaults（zone 只进配置不生效）。若服务被自动拉起（OpenWrt
#   惯例，apk 行为待确认）也无影响面：无设备配置 → PassWall 只多一段禁用
#   规则且不重启；首启会联网取一次 UU 本体。

uci show firewall.uu firewall.lan_uu     # review 点 1：确认 zone 与转发都写进去了
logread -e uuplugin                      #   没写进去必有一行 daemon.err 说明原因
fw4 check                                #   只是 nft 语法检查，别拿它当"规则有效"
fw4 reload                               # 唯一可能瞬断的点，建议配看门狗

/etc/init.d/uuplugin enable
/etc/init.d/uuplugin start               # 取本体、起进程；此时不碰 PassWall

# 手机 App 绑定（见下节）→ 确认 tun 出现、加速正常

service uuplugin scan                    # 找 NS2；找不到就 service uuplugin watch
service uuplugin add <mac> ns2           # review 点 2：这步会重启 PassWall，
                                         # 代理客户端瞬断数秒
```

回退：删 device 段后 reload（PassWall 即恢复）；完整卸载 = 删两个包 +
删 `firewall.uu`/`firewall.lan_uu`/`firewall.uu_lan` + 删 `passwall.uuplugin`
段 + 各自 reload + `rm -rf /etc/uuplugin`（guard 的检查点目录）。
卸 `uuplugin-bin` 时程序文件自动清掉，身份文件
（`.uuplugin_uuid`/`.sn`）自动保留（重装免重绑）；连身份一起彻底清除：
`rm -rf /usr/sbin/uu`。

## UU App 绑定

1. 手机装「UU加速器」App，**连本路由器的 Wi-Fi**（靠局域网发现，跨网段不行），
   网易账号登在 App 里，路由器不存任何凭据。
2. 加速 → 主机/游戏机加速 → 添加路由器 → 「已安装，直接绑定」。
3. 绑定后选中 NS2 开始加速，此时才会出现 `tun16x` 设备。
4. App 扫不到路由器的最常见原因是手机流量被 PassWall 代理：
   `service uuplugin add <手机mac>` 临时放行，绑定完删掉该段。

## 官方包审计结论（v14.2.2，2026-08-21）

- tar.gz 平铺 4 文件（uuplugin / xuplugin-guardian / xtables-nft-multi /
  uu.conf），无任何 install/init 脚本；guardian 是 libev 父进程守护小工具，
  主进程自行拉起。
- 硬编码 `/usr/sbin/uu/`，以 `./` 相对路径引用同目录文件 → init 必须 cd。
- 规则行为：优先用系统 iptables（`which iptables` 探测 → uuplugin-bin
  DEPENDS `+iptables-nft`）；`ip rule add from <IP> fwmark <m> lookup <N>`。
- `nft flush/delete table` 字符串的目标是它自建的 `ip <前缀>_nat` 表，
  不碰 fw4/passwall（首启快照仍会核对，清单见 docs/datapath.md §9）。
- 自升级：App 触发下载到 `/tmp/uu` 替换本体。
- 设备发现读 `/tmp/dhcp.leases`、`/proc/net/arp`。
- 端点：`gw.router.uu.163.com`、`devrglg.uu.163.com`、`log.uu.163.com`、
  `rglg.uu.netease.com`；API `router.uu.163.com`（https 可用）。

## 已知事项

- eShop/部分联机异常：App 的插件设置「本地 IPv4 绕过地址」加白冲突网段。
- `tun*` 通配把一切 tun 前缀接口纳入 uu zone。本机无冲突（PassWall 走
  tproxy，WireGuard 接口名 `wireguard`）；未来引入其它 tun 软件时改成
  显式设备列表。
- NS2 的 OUI 可能未收录（新硬件）：`/usr/share/uuplugin/nintendo-oui` 可
  直接追加，或用 `service uuplugin watch` 差分识别。
- 主机名特征表里的"匹配一切"规则会被拒收（三道闸，命中任何一道都是停用整表
  并告警，绝不放行）：行首行尾多余的 `|` 自动削掉；行内空分支 `a||b`；语法
  非法的正则；以及 `.`、`.*`、`^`、`$`、`[a-z0-9]` 这类语法合法却匹配一切的
  写法——最后这类从写法上跟 `switch` 毫无分别，只能实测：脚本拿两串哨兵（一
  串纯字母 + 一串纯数字，都是重复的冷僻字符，撞不上任何真规则）去试，**两串
  都命中**才判为通配。要两串是为了不把 `[a-z]`、`[0-9]` 这种"宽但仍挑字符类"
  的规则误杀——它们各只命中一串，整表停用对它们是过重的处置。
  为什么这么较真：一条匹配一切的规则会让 `classify` 把每台有主机名的设备都
  标成候选，`autoadd=1` 时 `cmd_auto` 逐台写 `device` 段、`render` 把这些 MAC
  全塞进 PassWall ACL 的 `sources`，nft 里每个 MAC 一条 `ether saddr <mac>
  counter return`——**全网设备一起脱离 PassWall**。
- 防呆闸只挡"匹配一切"，不挡"过宽"：`[a-z]` 实际上也命中几乎所有真实主机名，
  但它只命中字母哨兵，脚本会放行。宽到什么程度由写表的人负责。
- PassWall 的 `stop` 是否**同步**拆掉 `inet passwall` 表，至今没有核实过（本机
  没有 passwall 源码可查，CI 是从网上现拉现编的）。等待逻辑因此按最坏情况写成
  两段式（先等旧表消失、再等新表回来），代价是同步拆表的快设备上第一段会白等
  满 3 秒——那正是原来 `sleep 3` 的成本，不是新增的。哪天读到 passwall 的
  `app.sh`/`nftables.sh` 确认了拆表是同步的，第一段可以砍掉。
- 仍在用的写死值（有意保留，不属于"环境相关"）：guard 自检探针
  `223.5.5.5`/`119.29.29.29` + miui `generate_204`（均可用
  `uuplugin.main.health_target`/`health_url` 覆盖）、租约候选表的三条内置
  路径（会并上 UCI 里 dnsmasq 的 `leasefile`）、网络接口名默认值
  `lan`/`wan`（可用 `uuplugin.main.lan_iface`/`wan_iface` 覆盖）、本体安装
  路径 `/usr/sbin/uu`（网易二进制自己写死，改不了）。
