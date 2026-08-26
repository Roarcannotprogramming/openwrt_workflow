# 数据通路：表、链、以及一个包的完整旅程

本文描述 PassWall + UU 共存时，这台路由器上内核里实际存在的规则拓扑。
"√源码推导"= 从 PassWall `nftables.sh` 的 `load_acl()` 或 fw4 渲染逻辑推出，
"√strings"= 从 UU 二进制字符串取证，"⚠待实测"= 首启快照要核对的项。

## 1. 参与方：谁往内核里写了什么

| 所有者 | 表 | 写入机制 | 生命周期 |
|---|---|---|---|
| fw4 | `inet fw4` | UCI 声明式渲染 | fw4 reload 时整表重建 |
| PassWall | `inet passwall` | 自带 nftables.sh | passwall restart 时整表重建 |
| UU 插件 | `ip mangle` / `ip nat` / `ip filter` | iptables-nft 兼容层，运行期逐条 `-I`/`-D` | 随加速会话增删 |
| UU 插件 | `ip <前缀>_nat`（自建 nft 表，√strings：`nft list table ip %s_nat`）| `nft -f` | 它自己 flush/delete（**只动这张**）|
| UU 插件 | `ip rule` + 自建路由表 | `ip rule add from <IP> fwmark <m> lookup <N>`（√strings）| 随加速会话增删 |
| 内核 | conntrack | — | 贯穿所有 hook |

**核心语义**：同一 netfilter hook 上的多条 base chain 按 priority 串行执行，
`accept` 只终结**本链**的裁决，包必须在**每一条**链里存活；`drop`/`reject`
则立即终结。两条集成要求（PassWall ACL、fw4 zone）都由此推出。

## 2. prerouting hook：链序与规则

按 priority 从先到后（同 priority 跨表的顺序 = 注册顺序，**不可依赖**——
这是 ACL 必须存在的第二个理由：不能指望 UU 的链恰好排在 PassWall 前面）：

| priority | 链（表） | 对 NS2 的包做什么 |
|---|---|---|
| **-199** (filter) | `PREROUTING`（ip/ip6 XU_ACC_MAIN_mangle，√实测） | UU 打 fwmark（仅 App 选中的设备）——**先于 PassWall 执行，顺序确定** |
| -150 (mangle) | `PSW_MANGLE`（inet passwall） | **命中我们 ACL 的 RETURN**，不打 tproxy 标记（UDP 走这条）|
| **-149** (mangle+1) | `PREROUTING`（ip/ip6 XU_ACC_MAIN_nat，√实测） | UU 的 nat 段（闲置时空链）|
| -100 (dstnat) | `dstnat`（inet fw4） | 端口转发（本机无配置，空跳）|
| -100 (dstnat) | `PSW_NAT`（inet passwall） | **命中我们 ACL 的 RETURN**，不 REDIRECT（TCP 走这条，redirect 模式）|

实测修正（2026-08-21 首启观测）：UU **不是**写传统的 `ip mangle/nat` 兼容层
表，而是自建 `XU_ACC_MAIN_{filter,mangle,nat}` 六张表（ip+ip6），闲置时
全部是 policy accept 的空链；`nft flush/delete table` 的作用域就是这个
命名空间。路由器上原有的 `ip mangle`（qos_Default 等）是部署前即存在的
QoS 配置，与 UU 无关。

我们的 ACL 渲染进 PassWall 的实际规则（√实测 2026-08-23，NS2 已接入后的
nft 原文，非 default ACL 段位于链前部，先于一切分流逻辑命中）：

```
# DNS：ACL 无自有节点时，:53 重定向回本机直连 dnsmasq（load_acl else 分支）
ether saddr a4:c1:e8:ca:ec:f3 udp dport 53 counter redirect to :53 comment "uuplugin"
ether saddr a4:c1:e8:ca:ec:f3 tcp dport 53 counter redirect to :53 comment "uuplugin"
# 全端口无条件 RETURN（TCP/UDP 各链一套，tcp/udp_no_redir_ports=1:65535 的产物）
ip protocol tcp ether saddr a4:c1:e8:ca:ec:f3 counter return comment "uuplugin"
ip protocol udp ether saddr a4:c1:e8:ca:ec:f3 counter return comment "uuplugin"
meta l4proto tcp ether saddr a4:c1:e8:ca:ec:f3 counter return comment "uuplugin"
meta l4proto udp ether saddr a4:c1:e8:ca:ec:f3 counter return comment "uuplugin"
```

集成层写 PassWall 配置的三条实测铁律（违反任何一条 = 规则静默不渲染）：
1. ACL 段必须是**匿名段**——app.sh 启用总闸（第 2015 行）`grep "@acl_rule"`
   只统计匿名记法，命名段被整体无视（其迭代逻辑却支持命名段，不一致）；
2. `sources` 里写**裸 MAC**——app.sh 用 `ip_or_mac()` 分类后自加 `mac:` 前缀
   生成内部 source_list；UCI 里带前缀会分类失败 → source_list 空 → 零渲染；
3. 从 init 上下文重启 PassWall 必须**关闭 fd 1000**（rc.common 的服务
   flock），否则 sing-box 等长命子进程继承该 fd，把 uuplugin 的服务锁
   永久扣死。

**没有这两条会发生什么**：TCP 被 `PSW_NAT` REDIRECT 到 sing-box 本地端口
（游戏流量进代理，延迟毁掉）；UDP 中 443 会命中全局 `udp_proxy_drop_ports=443`
的 drop（QUIC 被丢）。这也是 ACL 里把 `*_proxy_drop_ports` 置 `disable` 的原因。

UU 侧的标记规则（√strings：`run iptables cmd`、`MARK`、p2p 端口匹配）：

```
iptables -w -t mangle -I PREROUTING -s <NS2的IP> -j MARK --set-mark <m>
# p2p 联机识别到的端口另有独立 mark 规则（⚠具体形态待实测）
```

## 3. 路由决策（prerouting 之后）

```
0:      from all lookup local
999:    fwmark 0x50535731 lookup 999        # PassWall tproxy 自用，仅匹配它的 mark
~32765: from <NS2的IP> fwmark <m> lookup <N> # UU 动态添加（√strings；pref 值⚠待实测）
32766:  from all lookup main
32767:  from all lookup default

# 表 N（UU 自建，√strings）：
default via <隧道对端> dev tun163
```

两套 fwmark 匹配条件正交（不同 mark 值），互不冲突。NS2 的包命中 UU 的
rule 后出口定为 tun163；其它设备走 main 表出 wan。

## 4. forward hook

| priority | 链（表） | 作用 |
|---|---|---|
| -150 (mangle) | `mangle_forward`（inet fw4） | `mtu_fix` 的 MSS clamp |
| 0 (filter) | `forward`（inet fw4） | **裁决点**：zone 放行在这里 |
| 0 (filter) | `FORWARD`（ip filter） | UU 自带的 ACCEPT（只终结本链，救不了 fw4 的 drop）|

fw4 侧我们的 zone 渲染出的结构（可用 `fw4 print` 核对）。下面按 stock 的
zone 名 `lan` 举例；uci-defaults 并不假设这个名字，而是去找**纳管 `lan`
网络的那个 zone**（`lan` 这个接口逻辑名可由 `uuplugin.main.lan_iface`
覆盖；zone 可能叫 `home`/`trust`），链名会跟着变成 `forward_home`、
`accept_to_home`——判别方式见 README「uci-defaults 怎么找 LAN 侧 zone」：

```
chain forward {
    type filter hook forward priority filter; policy drop;   # defaults forward=REJECT
    ct state established,related accept        # 回程与后续包在这里直接放行
    iifname "br-lan" jump forward_lan
    iifname "eth1"  jump forward_wan
    iifname "wireguard" jump forward_vpn
    iifname "tun*"  jump forward_uu            # ← zone uu，通配：tun163/tun164 都命中
    jump handle_reject                          # 谁都没 accept → reject
}
chain forward_lan  { jump accept_to_wan; jump accept_to_uu; ... }   # ← lan→uu forwarding
chain accept_to_uu { oifname "tun*" counter accept }
chain forward_uu   { jump accept_to_lan }                            # ← uu→lan forwarding
chain accept_to_lan{ oifname "br-lan" counter accept }
chain input_uu     { ... accept }   # zone input=ACCEPT（tun 来的对本机流量）
chain mangle_forward {
    iifname "tun*" tcp flags syn tcp option maxseg size set rt mtu   # mtu_fix 双向
    oifname "tun*" tcp flags syn tcp option maxseg size set rt mtu
}
```

UU 在 `ip filter` 里的 `-I FORWARD -i tun+ -j ACCEPT` / `-o tun+ -j ACCEPT`
（√strings）在 fw4 的 policy drop 面前不起作用——真正放行靠上面的 zone。
刻意不改 `defaults.forward`：那会给**所有**未被 zone 覆盖的转发开绿灯。

## 5. postrouting hook

| priority | 链（表） | 作用 |
|---|---|---|
| 100 (srcnat) | `srcnat`（inet fw4） | 只有 wan zone 有 masq；**uu zone masq=0** |
| 100 (srcnat) | `POSTROUTING`（ip nat） | UU 维护 `-o tun+ -j RETURN`（√strings），防兼容层里的 MASQUERADE 波及隧道 |

masq=0 是有意的：NS2 的原始源 IP 原样进入 tun，UU 据此区分是哪台设备的
流量；出口 NAT 在 UU 节点侧完成。

## 6. NS2 一个 TCP SYN 的完整旅程

```
NS2 (192.168.7.x) → br-lan 进入
 ├─ prerouting/-150  PSW_MANGLE:  ether saddr 命中 → return（无 tproxy 标记）
 ├─ prerouting/-150  ip mangle:   UU 打 fwmark <m>
 ├─ prerouting/-100  PSW_NAT:     ether saddr 命中 → return（无 REDIRECT）
 ├─ 路由决策:        from <IP> fwmark <m> → 表 N → 出口 tun163
 ├─ forward/-150     mangle_forward: SYN 的 MSS 钳到隧道 PMTU
 ├─ forward/0        fw4: iifname br-lan → forward_lan → accept_to_uu (oifname tun*) → accept
 ├─ forward/0        ip filter FORWARD: UU 的 ACCEPT（本链放行）
 ├─ postrouting/100  fw4 srcnat: uu zone 无 masq → 源 IP 保持
 └─ tun163 → uuplugin 用户态收包、封装
      └─ 封装后的外层流量 = 路由器本机发起：走 output hook → wan zone（masq 在
         这里对外层生效）→ UU 加速节点

回程：节点 → wan → uuplugin 进程解封 → 写入 tun163
 ├─ prerouting: 各链无命中（目的地址 NS2，无标记需求）
 ├─ 路由决策: dst=NS2 → main 表 → br-lan
 ├─ forward/0: 首包后 ct established accept 直接放行；首个回包走
 │            iifname tun* → forward_uu → accept_to_lan
 └─ br-lan → NS2
```

## 7. 对照组：未加速设备的包

`PSW_MANGLE`/`PSW_NAT` 里没有它的 RETURN → 正常走 PassWall 分流
（chn 直连 / 其余 REDIRECT/tproxy）；UU 的 mangle 链里没有它的 mark 规则
（App 未选中）→ 路由走 main 表。两个系统在 **ACL（MAC）** 和 **fwmark（IP）**
两个正交维度上互不干扰。

## 8. DNS

我们的 ACL 没设 tcp_port/udp_port，`load_acl()` 走 else 分支：NS2 的 :53
被引到**直连解析的 dnsmasq 实例**（√源码推导）——不经代理、不经 gfwlist
拦截，返回真实 IP，这正是 UU 需要的；游戏域名的解析 UU 还会在隧道内用
自己的 resolver 兜底（√strings：`dns_resolver.cpp`）。

## 9. 首启实测清单（2026-08-21 已全部核对）

- [x] UU 规则形态：自建 `XU_ACC_MAIN_{filter,mangle,nat}`（ip+ip6）六表，
      闲置时空链；mangle 段 priority **-199**（先于 PassWall 的 -150），
      nat 段 mangle+1（-149）
- [x] `ip rule`：闲置时零变化（加速会话建立时才添加，待绑定后二次观测）
- [x] 自建表真名：前缀 `XU_ACC_MAIN`，与二进制 strings 里的 `%s_nat` 吻合
- [x] `inet passwall`：链与规则逐字节不变，仅动态集合元素随 chinadns-ng
      运行自然增长；ACL 骨架在 UCI 中（禁用态），未渲染进 nft 属预期
- [x] `fw4 print` 的 `tun*` 通配渲染：已生效（演练 A 的受保护 reload）
- [x] `inet fw4` 启停前后（计数器归一后）逐字节不变
- [ ] 加速会话建立后的二次观测：mark 值、`ip rule` pref、表号、
      XU_ACC_MAIN 内的实际规则（待 App 绑定并开始加速）
