#!/bin/sh
# uuplugin-render / uuplugin.defaults 的逻辑测试。
# 纯 POSIX sh + python3，macOS / Linux 都能跑，不需要路由器。
#
# 原理：把脚本里的绝对路径（/lib/functions.sh、/etc/config/passwall、
# /etc/init.d/passwall）替换成沙箱路径，uci/nft/logger 用假实现顶掉，
# 然后按场景断言状态机行为。写操作记录在 oplog 里，用于证明幂等路径
# 上一次写都没发生。

set -eu

TESTS_DIR=$(cd "$(dirname "$0")" && pwd)
FILES_DIR=$(cd "${TESTS_DIR}/../files" && pwd)
PKG_DIR=$(cd "${TESTS_DIR}/.." && pwd)
BIN_FILES_DIR=$(cd "${TESTS_DIR}/../../uuplugin-bin/files" && pwd)
SANDBOX=$(mktemp -d /tmp/uuplugin-tests.XXXXXX)
trap 'rm -rf "$SANDBOX"' EXIT

export UCI_STATE="${SANDBOX}/uci.json"
export UCI_OPLOG="${SANDBOX}/oplog"
PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# 沙箱搭建
# ---------------------------------------------------------------------------

mkdir -p "${SANDBOX}/bin" "${SANDBOX}/etc/config" "${SANDBOX}/etc/init.d"

cat >"${SANDBOX}/bin/uci" <<EOF
#!/bin/sh
exec python3 '${TESTS_DIR}/fake-uci.py' "\$@"
EOF

# logger 桩：默认丢弃（几乎每个场景都会调它，刷屏没意义）；设了 LOGGER_LOG
# 就把消息（最后一个参数）记下来。有些行为唯一的出口就是日志——例如
# passwall_wait 非法时的回落告警、回滚里 uci commit 落不了盘那一句：不记下来
# 就只能断言"它没干那件坏事"，断不了"它吵过一声"。断言要钉在某一条分支独有
# 的原话上——"干成了"和"没干成"共用一句日志，正是上一轮出现"无理由变绿"的
# 那类断言的根源。
cat >"${SANDBOX}/bin/logger" <<'EOF'
#!/bin/sh
[ -n "${LOGGER_LOG:-}" ] || exit 0
msg=""
for a in "$@"; do msg="$a"; done
echo "$msg" >>"$LOGGER_LOG"
EOF

# sleep 桩：只有设了 FAKE_CLOCK 才假——把秒数累加进刻度文件后立刻返回，
# 于是"等了多久"变成可断言的确定量，测慢启动不必真睡几十秒。没设 FAKE_CLOCK
# 就原样交给真 sleep：guard 的看门狗、重试间隔等场景的时序一点没变
cat >"${SANDBOX}/bin/sleep" <<'EOF'
#!/bin/sh
[ -n "${FAKE_CLOCK:-}" ] || exec /bin/sleep "$@"
t=$(cat "$FAKE_CLOCK" 2>/dev/null) || t=0
echo $((${t:-0} + ${1:-0})) >"$FAKE_CLOCK"
EOF

# nft 桩，两件事：
#
# `list chain <family> <table> <chain>` 查 NFT_CHAIN_FILE 里的链名清单——这份
# 清单代表"内核当前状态"，fw4 桩 reload 成功时会往里追加 forward_uu。不能拿
# 静态答案糊弄：ensure_firewall 恰恰靠"reload 前没有、reload 后有"判断成败，
# 桩若一口咬定"有"，函数第一步就短路返回，整条 reload 路径连同它的回滚分支
# 一次都测不到。
#
# `list tables` 默认按 NFT_TABLES 决定"哪些表存在"（多张表用换行分隔）。设了
# NFT_CLOCK（＝假 sleep 维护的那个刻度文件）则改走时间线模式，用来复现
# PassWall 重启的三个阶段：
#   刻度 <  NFT_PW_GONE            旧表还没被拆掉（stop 若是异步的就是这一段）
#   NFT_PW_GONE ≤ 刻度 < NFT_PW_BACK  表已拆、新表还没建好
#   刻度 ≥ NFT_PW_BACK             新表建好；NFT_PW_BACK 留空＝永远回不来
cat >"${SANDBOX}/bin/nft" <<'EOF'
#!/bin/sh
if [ "$1 $2" = "list chain" ]; then
	case " $(tr '\n' ' ' 2>/dev/null <"${NFT_CHAIN_FILE:-/dev/null}") " in
	*" $5 "*) exit 0 ;;
	esac
	exit 1
fi
[ "$1 $2" = "list tables" ] || exit 0
if [ -n "${NFT_CLOCK:-}" ]; then
	t=$(cat "$NFT_CLOCK" 2>/dev/null) || t=0
	up=0
	[ "${t:-0}" -lt "${NFT_PW_GONE:-0}" ] && up=1
	[ -n "${NFT_PW_BACK:-}" ] && [ "${t:-0}" -ge "$NFT_PW_BACK" ] && up=1
	[ "$up" = 1 ] && printf 'table inet passwall\n'
	exit 0
fi
[ -n "${NFT_TABLES:-}" ] && printf '%s\n' "$NFT_TABLES"
exit 0
EOF

cat >"${SANDBOX}/etc/init.d/passwall" <<EOF
#!/bin/sh
echo "\$1" >>'${SANDBOX}/passwall-calls'
EOF

# guard 桩：记录调用序列，GUARD_HEALTH_RC 控制 health 结果（默认通过）
cat >"${SANDBOX}/guard" <<'EOF'
#!/bin/sh
echo "$1" >>"${GUARD_LOG:?}"
[ "$1" = "health" ] && exit "${GUARD_HEALTH_RC:-0}"
exit 0
EOF

# ping 桩：guard 的 health 只看退出码；sweep 的测试还要知道到底 ping 了谁，
# 故设了 PING_LOG 就把目标地址（最后一个参数）记下来
cat >"${SANDBOX}/bin/ping" <<'EOF'
#!/bin/sh
if [ -n "${PING_LOG:-}" ]; then
	last=""
	for a in "$@"; do last="$a"; done
	echo "$last" >>"$PING_LOG"
fi
exit "${PING_RC:-0}"
EOF
# uclient-fetch 桩：guard 只看退出码；uu-fetch 的测试要 URL（UCF_LOG）
# 与一份假响应（UCF_BODY 写进 -O 指定的文件）
cat >"${SANDBOX}/bin/uclient-fetch" <<'EOF'
#!/bin/sh
last=""
prev=""
out=""
for a in "$@"; do
	[ "$prev" = "-O" ] && out="$a"
	prev="$a"
	last="$a"
done
[ -n "${UCF_LOG:-}" ] && echo "$last" >>"$UCF_LOG"
[ -n "${UCF_BODY:-}" ] && [ -n "$out" ] && printf '%s' "$UCF_BODY" >"$out"
exit "${UCF_RC:-0}"
EOF
# jsonfilter 桩：只需支持 uu-fetch 用的 `-i <文件> -e '@.键'`，
# 假响应用 键=值 的行格式
cat >"${SANDBOX}/bin/jsonfilter" <<'EOF'
#!/bin/sh
key="${4#@.}"
sed -n "s/^${key}=//p" "$2"
EOF

chmod +x "${SANDBOX}/bin/"* "${SANDBOX}/etc/init.d/passwall" "${SANDBOX}/guard"
export PATH="${SANDBOX}/bin:${PATH}"
export UU_GUARD="${SANDBOX}/guard"
export GUARD_LOG="${SANDBOX}/guard-calls"

# guard 的状态目录（检查点 + 未验证标记）。必须在跑 uuplugin.defaults 之前
# 就指进沙箱：defaults 现在也会往这里写标记文件，而它的默认值是真机的
# /etc/uuplugin——以 root 跑测试时那会真的在本机 /etc 底下建目录。
export UU_GUARD_STATE="${SANDBOX}/guard-state"
UNPROVEN="${UU_GUARD_STATE}/firewall.unproven"
# 内核里"当前有哪些链"，见上面的 nft 桩
export NFT_CHAIN_FILE="${SANDBOX}/nft-chains"
: >"$NFT_CHAIN_FILE"

# 打补丁：只替换三个绝对路径，其余逐字节保持
sed -e "s|/lib/functions.sh|${TESTS_DIR}/functions.sh|" \
	-e "s|/etc/config/passwall|${SANDBOX}/etc/config/passwall|" \
	-e "s|/etc/init.d/passwall|${SANDBOX}/etc/init.d/passwall|" \
	"${FILES_DIR}/uuplugin-render" >"${SANDBOX}/render"
chmod +x "${SANDBOX}/render"

# ---------------------------------------------------------------------------
# 断言工具
# ---------------------------------------------------------------------------

check() { # check <描述> <命令...>
	local desc="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf '  ok  %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf 'FAIL  %s\n' "$desc"
	fi
}

uci_is() { # uci_is <ref> <期望值>
	[ "$(uci -q get "$1" || true)" = "$2" ]
}

# 匿名 ACL 段按 remarks 解析（与 render 的锚定方式一致）
acl_sid() {
	local s
	for s in $(uci -q _sections passwall acl_rule); do
		[ "$(uci -q get "passwall.${s}.remarks" || true)" = "uuplugin" ] && {
			echo "$s"
			return
		}
	done
}
acl_is() { uci_is "passwall.$(acl_sid).$1" "$2"; }
acl_exists() { [ -n "$(acl_sid)" ]; }

oplog_reset() { : >"$UCI_OPLOG"; }
oplog_empty() { [ ! -s "$UCI_OPLOG" ]; }
restart_count() {
	if [ -f "${SANDBOX}/passwall-calls" ]; then
		wc -l <"${SANDBOX}/passwall-calls" | tr -d ' '
	else
		echo 0
	fi
}

scenario() {
	printf '\n== %s ==\n' "$1"
}

# ---------------------------------------------------------------------------
# 场景
# ---------------------------------------------------------------------------

scenario "0. 静态约束：source /lib/functions.sh 的脚本禁用 set -u"
# 真机教训：OpenWrt 的 /lib/functions.sh 裸引用 IPKG_INSTROOT 等，
# set -u 下 source 即炸；沙箱用假 functions.sh 掩盖不了这一点，故静态断言
check "render 不含 set -u" sh -c "! grep -qx 'set -u' '${FILES_DIR}/uuplugin-render'"
check "scan 不含 set -u" sh -c "! grep -qx 'set -u' '${FILES_DIR}/uuplugin-scan'"
# 真机教训 2：rc.common 用 fd 1000 持有服务 flock；派生长命进程（setsid
# 看门狗、跨服务 restart 的子进程）必须关掉该 fd，否则锁被永久扣死
check "render 的 passwall restart 关闭锁 fd" \
	grep -q "passwall restart 1000>&-" "${FILES_DIR}/uuplugin-render"
check "guard 的派生/重启点全部关闭锁 fd（4 处）" \
	sh -c "[ \$(grep -c '1000>&-' '${FILES_DIR}/uuplugin-guard') -eq 4 ]"
# mipsel/arm 上 shell 算术是 32 位有符号的：把 IP 拼成整数（o1<<24）会溢出
# 成负数，扫描会静默走错网段。这类 bug 在 64 位测试机上根本复现不出来，
# 只能静态挡住"整数化 IP"这种写法
check "scan 不做会在 32 位上溢出的整数 IP 运算" \
	sh -c "! grep -v '^[[:space:]]*#' '${FILES_DIR}/uuplugin-scan' |
		grep -qE '<<[[:space:]]*24|16777216'"
# OpenWrt 的 /var 是指向 /tmp 的软链。检查点是"掉电后仍是已知良好配置"
# 这条保证的唯一载体，落进内存盘等于没有兜底。
# 而且必须是 /etc，光"某个持久目录"不够：sysupgrade -c 的保留清单就是
# SAVE_OVERLAY_PATH=/etc，/root 虽然也在 overlay 上，却会在升级固件时
# 连检查点一起消失——"刚升完级"恰恰是最需要它的时刻。
check "guard 的检查点默认落在 /etc（sysupgrade -c 会保留）" \
	grep -qF 'UU_GUARD_STATE:-/etc/uuplugin' "${FILES_DIR}/uuplugin-guard"
# 未验证标记由三个文件共享：defaults 建、guard 读+删、init 删。三处各自写了
# 一遍 ${UU_GUARD_STATE:-/etc/uuplugin}，谁漂一个字，另外两个就永远看不见它的
# 标记——而症状是"什么都没发生"：回滚照样报成功，只是那三段再没人拆得掉。
# 沙箱里 UU_GUARD_STATE 是导出的，运行期测试对这种漂移一无所知，只能静态钉。
check "init 里的状态目录默认值与 guard 逐字一致" \
	grep -qF 'UU_GUARD_STATE:-/etc/uuplugin' "${FILES_DIR}/uuplugin.init"
check "uci-defaults 里的状态目录默认值与 guard 逐字一致" \
	grep -qF 'UU_GUARD_STATE:-/etc/uuplugin' "${FILES_DIR}/uuplugin.defaults"
check "标记文件名三处一致（firewall.unproven）" sh -c \
	"[ \$(grep -lF 'firewall.unproven' '${FILES_DIR}/uuplugin-guard' \
		'${FILES_DIR}/uuplugin.init' '${FILES_DIR}/uuplugin.defaults' | wc -l) -eq 3 ]"
check "主机名特征表随包安装" grep -q 'hostname-hints' "${PKG_DIR}/Makefile"
# 两张表都明说了"可以自己加行"，那就必须是 conffiles——否则升级一次包，
# INSTALL_DATA 把用户加的规则直接盖掉，而且不留痕迹
conffiles_has() {
	awk '/^define Package\/uuplugin\/conffiles/,/^endef/' "${PKG_DIR}/Makefile" |
		grep -q "$1"
}
check "主机名表登记为 conffiles" conffiles_has 'hostname-hints'
check "OUI 表登记为 conffiles" conffiles_has 'nintendo-oui'
# usage() 曾写死 sed -n '2,23p'：头部注释一增删就对不上，而且没人会发现——
# 自己的帮助文本悄悄少半截，正是那种没有任何人会报的 bug
no_hardcoded_header_range() {
	! grep -hE "sed -n '[0-9]+,[0-9]+p'" \
		"${FILES_DIR}/uuplugin-scan" "${FILES_DIR}/uuplugin-guard" \
		"${BIN_FILES_DIR}/uu-fetch" >/dev/null
}
check "三个脚本的自述帮助不写死行号" no_hardcoded_header_range
# 只该剩默认值那一处；多出来的就是漏改的写死点
check "uu-fetch 里的 API 主机只剩默认值一处" \
	sh -c "[ \$(grep -c 'router\.uu\.163\.com' '${BIN_FILES_DIR}/uu-fetch') -eq 1 ]"
# 出厂配置显式写了一批默认值，代码侧各留了一份内置默认（render 的
# PW_WAIT_DEFAULT、guard 的 _cfg 第二参、scan/init 的 config_get_bool 第四参）。
# 两边没有任何东西钉着：谁改了代码默认值，全新安装照样用出厂文件里的旧值，
# 改了等于没改，而且无声。抠出两边的字面值硬比，谁漂谁现形。
cfg_default() { # $1=键 -> uuplugin.config 里未注释的出厂显式值
	sed -n "s/^[[:space:]]*option $1 '\([^']*\)'.*/\1/p" "${FILES_DIR}/uuplugin.config"
}
CFG_PW_WAIT=$(cfg_default passwall_wait)
check "出厂配置显式写了 passwall_wait" [ -n "$CFG_PW_WAIT" ]
check "render 的 PW_WAIT_DEFAULT 与出厂值一致" \
	grep -qx "PW_WAIT_DEFAULT=${CFG_PW_WAIT}" "${FILES_DIR}/uuplugin-render"
CFG_GRACE=$(cfg_default guard_timeout)
check "出厂配置显式写了 guard_timeout" [ -n "$CFG_GRACE" ]
# 先钉 guard 自己内部一致：protect 与 watch 两个调用点各写了一遍默认值，
# 谁单独漂了都算错；再钉这份唯一写法等于出厂值
check "guard 里 guard_timeout 的默认值只有一种写法" sh -c \
	"[ \$(grep -o '_cfg guard_timeout [0-9][0-9]*' '${FILES_DIR}/uuplugin-guard' |
		sort -u | wc -l) -eq 1 ]"
GUARD_GRACE=$(grep -o '_cfg guard_timeout [0-9][0-9]*' "${FILES_DIR}/uuplugin-guard" |
	sort -u | grep -o '[0-9][0-9]*')
check "guard 的 guard_timeout 默认值与出厂值一致" [ "$GUARD_GRACE" = "$CFG_GRACE" ]
# 三个布尔同理。main.enabled 的默认在 render 与 init 各写了一处，先并起来
# 钉彼此一致（sort -u 出两行就说明漂了），再钉等于出厂值
bool_default() { # $1=键 $2...=文件 -> config_get_bool main.$1 的默认参数
	grep -ho "main $1 [01]" "$@" | sort -u | grep -o '[01]$'
}
CFG_ENABLED=$(cfg_default enabled)
CFG_AUTODETECT=$(cfg_default autodetect)
CFG_AUTOADD=$(cfg_default autoadd)
check "出厂配置显式写了 enabled/autodetect/autoadd" sh -c \
	"[ -n '$CFG_ENABLED' ] && [ -n '$CFG_AUTODETECT' ] && [ -n '$CFG_AUTOADD' ]"
check "enabled 的代码默认与出厂值一致（render 与 init 两处）" \
	[ "$(bool_default enabled "${FILES_DIR}/uuplugin-render" "${FILES_DIR}/uuplugin.init")" = "$CFG_ENABLED" ]
check "autodetect 的代码默认与出厂值一致" \
	[ "$(bool_default autodetect "${FILES_DIR}/uuplugin-scan")" = "$CFG_AUTODETECT" ]
check "autoadd 的代码默认与出厂值一致" \
	[ "$(bool_default autoadd "${FILES_DIR}/uuplugin-scan")" = "$CFG_AUTOADD" ]
# guard 的内置探针默认值在出厂配置里只以注释形式示人——注释是用户唯一能
# 看到内置默认的地方，代码改了而注释没跟上，等于文档撒谎
GUARD_HT=$(sed -n 's/.*_cfg health_target "\([^"]*\)".*/\1/p' "${FILES_DIR}/uuplugin-guard")
GUARD_HU=$(sed -n 's/.*_cfg health_url "\([^"]*\)".*/\1/p' "${FILES_DIR}/uuplugin-guard")
check "guard 内置探针默认值抠得出来（防这颗钉子自己空转）" sh -c \
	"[ -n '$GUARD_HT' ] && [ -n '$GUARD_HU' ]"
check "出厂配置注释里的 ICMP 探针默认与 guard 内置一致" \
	grep -qF "$GUARD_HT" "${FILES_DIR}/uuplugin.config"
check "出厂配置注释里的 HTTP 探针默认与 guard 内置一致" \
	grep -qF "$GUARD_HU" "${FILES_DIR}/uuplugin.config"

scenario "1. PassWall 配置缺失（依赖破损的异常态）：报错退出，零写入"
uci set uuplugin.main=uuplugin
uci set uuplugin.main.enabled=1
oplog_reset
rc=0
"${SANDBOX}/render" || rc=$?
check "以退出码 1 报错" [ "$rc" = "1" ]
check "无写操作" oplog_empty

scenario "2. PassWall 存在、无设备：创建禁用的骨架段"
touch "${SANDBOX}/etc/config/passwall"
uci set passwall.g0=global
uci set passwall.g0.acl_enable=0
oplog_reset
check "退出码 0" "${SANDBOX}/render"
check "段已创建" acl_exists
check "禁用状态" acl_is enabled 0
check "全端口不重定向" acl_is tcp_no_redir_ports 1:65535
check "不动全局 acl_enable" uci_is passwall.g0.acl_enable 0
check "未重启 passwall（本来就没在跑）" [ "$(restart_count)" = "0" ]

scenario "3. 立即重跑：幂等，零写入"
oplog_reset
check "退出码 0" "${SANDBOX}/render"
check "无写操作" oplog_empty

scenario "3b. 骨架被删后在 PassWall 运行中重建：只落配置，不打扰运行中的代理"
uci delete "passwall.$(acl_sid)"
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "骨架已重建" acl_exists
check "未重启 passwall（禁用→禁用无运行时差异）" [ "$(restart_count)" = "0" ]

scenario "4. 添加 NS2：启用 + sources + acl_enable，passwall 在跑则重启"
uci set uuplugin.ns2=device
uci set uuplugin.ns2.name=ns2
uci set uuplugin.ns2.mac='98:B6:E9:12:34:56'
oplog_reset
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "启用" acl_is enabled 1
check "MAC 归一化为小写" acl_is sources '98:b6:e9:12:34:56'
check "打开全局 acl_enable" uci_is passwall.g0.acl_enable 1
check "重启了 passwall" [ "$(restart_count)" = "1" ]

scenario "5. 重跑（MAC 改成小写写法）：语义相同，零写入零重启"
uci set uuplugin.ns2.mac='98:b6:e9:12:34:56'
oplog_reset
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "无写操作" oplog_empty
check "未再重启 passwall" [ "$(restart_count)" = "1" ]

scenario "6. 追加第二台设备：sources 变为两项"
uci set uuplugin.ps5=device
uci set uuplugin.ps5.mac='AA:BB:CC:DD:EE:FF'
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "两个来源" acl_is sources '98:b6:e9:12:34:56 aa:bb:cc:dd:ee:ff'

scenario "7. 禁用一台设备：从 sources 移除"
uci set uuplugin.ps5.enabled=0
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "只剩 NS2" acl_is sources '98:b6:e9:12:34:56'

scenario "8. 非法 MAC：跳过该设备并以退出码 1 报错，其余设备不受影响"
uci set uuplugin.bad=device
uci set uuplugin.bad.mac='not-a-mac'
rc=0
NFT_TABLES='table inet passwall' "${SANDBOX}/render" || rc=$?
check "退出码 1" [ "$rc" = "1" ]
check "合法设备仍在" acl_is sources '98:b6:e9:12:34:56'
uci delete uuplugin.bad

scenario "9. 删光设备：回到禁用骨架，sources 清空"
uci delete uuplugin.ns2
uci set uuplugin.ps5.enabled=1
uci delete uuplugin.ps5
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "禁用" acl_is enabled 0
check "sources 已清空" acl_is sources ''
check "启用→禁用要重启 passwall 清掉运行时规则" [ "$(restart_count)" = "4" ]

cp "${FILES_DIR}/uuplugin.defaults" "${SANDBOX}/defaults"
chmod +x "${SANDBOX}/defaults"
uci_missing() { ! uci -q get "$1" >/dev/null 2>&1; }
run_defaults() { # -> rc 写进 $rc
	rc=0
	"${SANDBOX}/defaults" >/dev/null 2>&1 || rc=$?
}

scenario "10. 找不到纳管 lan 的 zone：一个字都不写，报错退出等下次重试"
# 不能"找不到就按 lan 写"：fw4 对解析不到的 zone 名只是 warn 一句跳过这条
# forwarding，ruleset 照常下发、forward_uu 链照常建、fw4 check 照常通过——
# 于是"加速全程不通"会被 ensure_firewall、status_service 一路报成绿色。
oplog_reset
run_defaults
check "以退出码 1 报错（脚本留给下次开机重试）" [ "$rc" = "1" ]
check "没建 uu zone" uci_missing firewall.uu
check "没写指向空处的 lan->uu 转发" uci_missing firewall.lan_uu
check "没写指向空处的 uu->lan 转发" uci_missing firewall.uu_lan
check "无写操作" oplog_empty
# 标记的含义是"这三段进了持久配置但没人验证过"。一个字都没写就没有这回事，
# 标上了只会让下一次回滚白拆一遍用户的配置
check "什么都没写，就不该留下未验证标记" [ ! -f "$UNPROVEN" ]

scenario "10b. stock 形态：匿名 zone（@zone[0]）也要认得出来"
# 真机的 /etc/config/firewall 里 zone 全是匿名 section，uci show 印成
# @zone[0]、@zone[1]。这是每台路由器上都会跑到的那条路径，必须覆盖。
# wan 故意排在 lan 前面：靠"挑第一个有 network 的 zone"蒙对不算认出来。
Z=$(uci add firewall zone)
uci set "firewall.${Z}.name=wan"
uci add_list "firewall.${Z}.network=wan"
Z=$(uci add firewall zone)
uci set "firewall.${Z}.name=lan"
uci add_list "firewall.${Z}.network=lan"
check "沙箱确实产出了匿名形态" sh -c \
	"uci show firewall | grep -qx 'firewall.@zone\[0\]=zone'"
run_defaults
check "退出码 0" [ "$rc" = "0" ]
check "zone 已建" uci_is firewall.uu zone
check "通配设备" uci_is firewall.uu.device 'tun*'
check "mtu_fix" uci_is firewall.uu.mtu_fix 1
check "lan->uu 的源是 lan" uci_is firewall.lan_uu.src lan
check "lan->uu 的目标是 uu" uci_is firewall.lan_uu.dest uu
check "uu->lan 的目标是 lan" uci_is firewall.uu_lan.dest lan
check "没有误挑排在前面的 wan zone" sh -c \
	"[ \"\$(uci -q get firewall.lan_uu.src)\" != wan ]"
oplog_reset
run_defaults
check "重跑零写入" oplog_empty

scenario "10c. LAN zone 被改过名：转发指向真实 zone 名，不写死 lan"
# 真实世界里 zone 名常被改成 home/trust，一个 zone 也可能纳管多个 network
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci delete 'firewall.@zone[1]' # 摘掉那个 name=lan 的匿名 zone，只留 wan
uci set firewall.z_home=zone
uci set firewall.z_home.name=home
uci set firewall.z_home.network='lan guest'
run_defaults
check "lan->uu 的源是 home" uci_is firewall.lan_uu.src home
check "uu->lan 的目标是 home" uci_is firewall.uu_lan.dest home
check "没有误挑 wan zone" sh -c \
	"[ \"\$(uci -q get firewall.lan_uu.src)\" != wan ]"

scenario "10d. network.lan 用 option zone 反向声明归属"
# fw4 的 parse_zone 会把 ubus 里 zone 字段等于本 zone 名的接口并进来，
# 配置侧对应的就是 network.lan.zone。注意 fw4 并没有"zone 省略 network
# 就拿 zone 名当 network 名用"这条规则——那是 fw3 的语义，别按它写。
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci delete firewall.z_home
uci set firewall.z_bare=zone
uci set firewall.z_bare.name=trust
uci set network.lan=interface
uci set network.lan.zone=trust
run_defaults
check "认出 network.lan.zone 指向的 zone" uci_is firewall.lan_uu.src trust

scenario "10e. network.lan.zone 指到一个不存在的 zone：当没说，继续按 network 列表找"
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci set network.lan.zone=ghost
uci set firewall.z_bare.network=lan
run_defaults
check "回落到 network 列表的匹配结果" uci_is firewall.lan_uu.src trust

scenario "10f. 装好之后 zone 被改名：不当作已装好，重跑改指新名字"
# "已装好"的判据不是"我们写过"，而是"转发这会儿确实指向一个存在的 zone"
uci set firewall.z_bare.name=trusted
oplog_reset
run_defaults
check "确实重写了（没被误判成已装好）" sh -c "[ -s \"\$UCI_OPLOG\" ]"
check "转发跟着改到新 zone 名" uci_is firewall.lan_uu.src trusted
check "uu->lan 也跟着改" uci_is firewall.uu_lan.dest trusted

scenario "10g. 同名 section 已被别的类型占用：整段跳过，不改写用户的配置"
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci set firewall.lan_uu=rule
oplog_reset
run_defaults
check "退出码 0（交人工处理，不反复重试）" [ "$rc" = "0" ]
check "没建 uu zone" uci_missing firewall.uu
check "没改写用户的同名 section" uci_is firewall.lan_uu rule
check "无写操作" oplog_empty

scenario "10h. 有个 zone 恰好叫 lan 却不纳管任何 network：按 fw4 语义跳过它"
# fw3 有"zone 省略 network 就拿 zone 名当 network 名"的兜底，fw4 没有。
# 按 fw3 那套写，这里会挑中名叫 lan 的空壳 zone——fw4 压根不往它里面归
# 任何流量，转发写上去等于没写，而且一路自检全绿。空壳故意排在前面：
# 靠"取最后一个匹配"蒙对不算按语义找。
uci delete firewall.lan_uu # 10g 留下的那个 rule
uci delete firewall.z_bare
uci delete network.lan.zone
uci set firewall.z_shell=zone
uci set firewall.z_shell.name=lan # 名字叫 lan，但没有 network 列表
uci set firewall.z_real=zone
uci set firewall.z_real.name=home
uci add_list firewall.z_real.network=lan
run_defaults
check "退出码 0" [ "$rc" = "0" ]
check "挑的是真正纳管 lan 网络的 home" uci_is firewall.lan_uu.src home
check "没被 fw3 语义骗去挑那个空壳 lan zone" sh -c \
	"[ \"\$(uci -q get firewall.lan_uu.src)\" != lan ]"

scenario "10i. 遍历 zone 时必须关掉路径展开（@zone[0] 本身就是合法通配符）"
# uci show 把匿名 section 印成 @zone[0]，而 [] 在 shell 里是字符类：只要
# 当前目录下恰好有个叫 @zone0 的文件，未加 set -f 的 for 就会把它替换成
# 那个文件名，于是所有 zone 一个都认不出来。uci-defaults 由 /etc/init.d/boot
# 执行，当前目录里有什么并不由我们决定，这条不能靠"一般不会有"来赌。
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci delete firewall.z_shell
uci delete firewall.z_real
uci delete 'firewall.@zone[0]' # 摘掉 10b 留下的 wan，让新 zone 落回 @zone[0]
Z=$(uci add firewall zone)
uci set "firewall.${Z}.name=lan"
uci add_list "firewall.${Z}.network=lan"
GLOBDIR="${SANDBOX}/globtrap"
mkdir -p "$GLOBDIR"
: >"${GLOBDIR}/@zone0" # 恰好能被 @zone[0] 匹配上的文件名
: >"${GLOBDIR}/@zone1"
check "陷阱目录里确实有能被 @zone[N] 命中的文件" sh -c \
	"cd '$GLOBDIR' && [ \"\$(echo @zone[0])\" = '@zone0' ]"
rc=0
(cd "$GLOBDIR" && "${SANDBOX}/defaults") >/dev/null 2>&1 || rc=$?
check "当前目录有 @zone0 也照样认得出匿名 zone" [ "$rc" = "0" ]
check "转发指向 lan" uci_is firewall.lan_uu.src lan

scenario "10j. uci batch 写到一半失败：不许把半成品当成装好了"
# batch 是逐行执行的，中途失败会留下"zone 建好了、转发没建"的残骸——而
# zone 恰恰是 init 的 ensure_firewall 用来判断"装好了"的东西。没有写后
# 验收，这个半成品会被当成成功，之后每一处自检都报绿，唯独加速不通。
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
rc=0
UCI_REFUSE='^set firewall\.lan_uu' "${SANDBOX}/defaults" >/dev/null 2>&1 || rc=$?
check "以退出码 1 报错（脚本留给下次开机重试）" [ "$rc" = "1" ]
check "半成品确实产生了（证明这一路真的走到了写入）" uci_is firewall.uu zone
check "转发确实没写进去" uci_missing firewall.lan_uu

scenario "10k. 写成功才留下\"未验证\"标记；早退路径不留"
# 这三段是整套回滚里唯一没被检查点覆盖的东西：本脚本装包时就把它们 commit
# 进 /etc/config/firewall 了，而让它们生效的 fw4 reload 要等到后来 init 的
# ensure_firewall 才发生——那会儿 protect 取的检查点里已经躺着它们，还原
# 等于什么都没还原。所以回滚的授权只能诞生在这里：标记 = 写进去了但还没人
# 证明它无害，在被证明之前 guard restore 有权把它拆掉。
uci delete firewall.uu # 清掉 10j 留下的半成品
rm -f "$UNPROVEN"
run_defaults
check "退出码 0" [ "$rc" = "0" ]
check "写成功后留下未验证标记" [ -f "$UNPROVEN" ]
# 这个目录接着要装 guard 的检查点，里面有 passwall 的代理凭据
check "状态目录不是顶着默认 umask 落成的 0755" sh -c \
	"[ \"\$(ls -ld '$UU_GUARD_STATE' | cut -c1-10)\" = 'drwx------' ]"
# 包升级会重跑 uci-defaults。那时 installed 已成立、走早退路径一个字没写——
# 在那儿也标一次，下一次任何原因的回滚都会白拆一遍用户用了很久的配置
rm -f "$UNPROVEN"
oplog_reset
run_defaults
check "重跑走的确实是早退路径（零写入）" oplog_empty
check "早退路径不标未验证（已在跑的配置不是新写入）" [ ! -f "$UNPROVEN" ]

# ---------------------------------------------------------------------------
# uu-scan
# ---------------------------------------------------------------------------

# 假 ip：neigh 输出来自 FAKE_NEIGH 环境变量；记录调用参数供断言
cat >"${SANDBOX}/bin/ip" <<'EOF'
#!/bin/sh
echo "ip $*" >>"${IP_LOG:-/dev/null}"
case "$*" in
*neigh*) [ -n "${FAKE_NEIGH:-}" ] && printf '%s\n' "$FAKE_NEIGH" ;;
esac
exit 0
EOF
chmod +x "${SANDBOX}/bin/ip"
export IP_LOG="${SANDBOX}/ip-calls"

# 两条替换互不干扰：/lib/functions.sh 与 /lib/functions/network.sh 在
# "functions" 之后一个是 "."、一个是 "/"，谁也匹配不到谁。
# 三条内置租约候选路径也指进沙箱：测试跑在开发机上，不能去读写真 /tmp
# ——别的进程随时可能在那儿留同名文件。发布文件里的真实路径由 23a 的静态
# 钉子钉住。次序要紧：/tmp/var/... 含 /var/... 作子串，先换长的，短的才
# 不会把它截胡。
BL_DIR="${SANDBOX}/lease-candidates"
mkdir -p "$BL_DIR"
sed -e "s|/lib/functions.sh|${TESTS_DIR}/functions.sh|" \
	-e "s|/lib/functions/network.sh|${TESTS_DIR}/network.sh|" \
	-e "s|/tmp/var/lib/misc/dnsmasq.leases|${BL_DIR}/tmpvar-dnsmasq.leases|" \
	-e "s|/var/lib/misc/dnsmasq.leases|${BL_DIR}/var-dnsmasq.leases|" \
	-e "s|/tmp/dhcp.leases|${BL_DIR}/dhcp.leases|" \
	"${FILES_DIR}/uuplugin-scan" >"${SANDBOX}/uu-scan"
chmod +x "${SANDBOX}/uu-scan"

export UU_OUI_FILE="${FILES_DIR}/nintendo-oui"
export UU_LEASES="${SANDBOX}/leases"
export UU_INIT="${SANDBOX}/no-such-init"
export UU_RENDER="${SANDBOX}/render"
export UU_LAN_DEV=br-lan
: >"$UU_LEASES"

dev_count() { uci -q _sections uuplugin device | wc -l | tr -d ' '; }
dev_has_mac() {
	local s
	for s in $(uci -q _sections uuplugin device); do
		[ "$(uci -q get "uuplugin.${s}.mac")" = "$1" ] && return 0
	done
	return 1
}

scenario "11. uu-scan add：手动加入 + 幂等 + 触发渲染"
"${SANDBOX}/uu-scan" add 'DC:68:EB:11:22:33' ns2test >/dev/null
check "设备段已创建且 MAC 小写" dev_has_mac 'dc:68:eb:11:22:33'
check "渲染已跟进（passwall sources 更新）" \
	acl_is sources 'dc:68:eb:11:22:33'
check "ACL 已启用" acl_is enabled 1
"${SANDBOX}/uu-scan" add 'dc:68:eb:11:22:33' >/dev/null
check "重复加入不产生新段" [ "$(dev_count)" = "1" ]
rc=0
"${SANDBOX}/uu-scan" add 'zz:bad:mac' 2>/dev/null || rc=$?
check "非法 MAC 拒绝" [ "$rc" = "1" ]

scenario "12. uu-scan auto：autodetect 只提示，autoadd 才落配置"
printf '1734567890 98:B6:E9:AA:BB:CC 192.168.7.50 * 01:98:b6:e9:aa:bb:cc\n' >"$UU_LEASES"
"${SANDBOX}/uu-scan" auto
check "autoadd=0：候选不入配置" [ "$(dev_count)" = "1" ]
uci set uuplugin.main.autoadd=1
"${SANDBOX}/uu-scan" auto
check "autoadd=1：任天堂 OUI 设备自动加入" dev_has_mac '98:b6:e9:aa:bb:cc'
check "渲染已跟进（两个来源）" \
	acl_is sources 'dc:68:eb:11:22:33 98:b6:e9:aa:bb:cc'
"${SANDBOX}/uu-scan" auto
check "重跑不重复加入" [ "$(dev_count)" = "2" ]
uci set uuplugin.main.autodetect=0
printf '1734567891 7C:BB:8A:00:11:22 192.168.7.51 * *\n' >>"$UU_LEASES"
"${SANDBOX}/uu-scan" auto
check "autodetect=0：整体关闭" [ "$(dev_count)" = "2" ]

scenario "12b. 未指定 LAN 设备名时按默认解析（真机 bug 的回归绊网）"
# 曾因 list/auto 漏调 resolve_lan 导致 ip neigh show dev "" 静默失败、
# 清单只剩 DHCP 租约；测试全程设着 UU_LAN_DEV 掩盖了它，故显式断言默认路径
: >"$IP_LOG"
env -u UU_LAN_DEV "${SANDBOX}/uu-scan" list >/dev/null 2>&1
check "邻居表按 br-lan 查询而非空设备名" grep -q "dev br-lan" "$IP_LOG"

scenario "13. main.enabled=0：清空 ACL，设备回到 PassWall"
restarts_before=$(restart_count)
uci set uuplugin.main.enabled=0
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "ACL 已禁用" acl_is enabled 0
check "sources 已清空" acl_is sources ''
check "启用→禁用触发了 passwall 重启" \
	[ "$(restart_count)" = "$((restarts_before + 1))" ]
check "device 段本身保留（配置不丢）" [ "$(dev_count)" = "2" ]
uci set uuplugin.main.enabled=1
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "重新启用后设备列表原样恢复" \
	acl_is sources 'dc:68:eb:11:22:33 98:b6:e9:aa:bb:cc'

scenario "14. PassWall 重启后自检失败：调用 guard 回滚且退出码非 0"
: >"$GUARD_LOG"
uci set uuplugin.main.enabled=0
rc=0
GUARD_HEALTH_RC=1 NFT_TABLES='table inet passwall' "${SANDBOX}/render" || rc=$?
check "退出码 1" [ "$rc" = "1" ]
check "先布防（protect）" grep -qx protect "$GUARD_LOG"
check "后回滚（restore）" grep -qx restore "$GUARD_LOG"
rc=0
grep -qx commit "$GUARD_LOG" && rc=1
check "未确认成功（无 commit）" [ "$rc" = "0" ]
# 恢复：自检通过的正常路径收尾，protect→commit
: >"$GUARD_LOG"
uci set uuplugin.main.enabled=1
NFT_TABLES='table inet passwall' "${SANDBOX}/render"
check "成功路径 protect→commit 成对出现" sh -c \
	"grep -qx protect '$GUARD_LOG' && grep -qx commit '$GUARD_LOG'"

# --- PassWall 重启的等待：把"秒"换成可数的刻度 -------------------------------
# 假 sleep 不睡，只把秒数累加进刻度文件；假 nft 按刻度回答"表在不在"。于是
# "等了多久"是确定量，"表在第 N 秒回来"可复现，套件也不会真的睡几十秒。
CLOCK="${SANDBOX}/clock"
LOGGER_LOG="${SANDBOX}/logger-log"
export LOGGER_LOG

run_render_timed() { # run_render_timed <旧表消失的刻度> <新表回来的刻度|空=永不> [VAR=VAL ...]
	local gone="$1" back="$2"
	shift 2
	echo 0 >"$CLOCK"
	: >"$GUARD_LOG"
	: >"$LOGGER_LOG"
	rr_rc=0
	env FAKE_CLOCK="$CLOCK" NFT_CLOCK="$CLOCK" \
		NFT_PW_GONE="$gone" NFT_PW_BACK="$back" "$@" \
		"${SANDBOX}/render" || rr_rc=$?
}
ticks() { cat "$CLOCK"; }
# 每次都翻转 main.enabled，保证这一趟确有"有运行时效果的变更"、真会走重启
pw_toggle=1
flip_enabled() {
	pw_toggle=$((1 - pw_toggle))
	uci set "uuplugin.main.enabled=$pw_toggle"
}

scenario "14b. 慢机器：表在第 8 秒才回来，照样算重启成功（不再误判）"
# 真机场景：MT7621 上 PassWall 重启要停 sing-box/chinadns-ng、flush 整张
# inet passwall 表、重跑 nftables.sh、再把 chnroute/gfwlist 几万条元素灌回
# nft set——光最后一步就不止 3 秒。写死 sleep 3 + 单次检查时，慢机器上每次
# 改设备列表都被判成重启失败而走进 guard restore：ACL 白写、PassWall 挨第二
# 次重启、uuplugin 被 stop + disable（重启也不会自己回来）。用户视角只是
# add 报了个失败，然后设备再也不加速。
flip_enabled
restarts_before=$(restart_count)
run_render_timed 1 8 UU_PASSWALL_WAIT=20
check "退出码 0（等到了就是成功）" [ "$rr_rc" = "0" ]
check "确认成功（commit）" grep -qx commit "$GUARD_LOG"
check "没有触发回滚" sh -c "! grep -qx restore '$GUARD_LOG'"
check "日志走的是成功那句" grep -q "并重启生效" "$LOGGER_LOG"
check "确实等过了第 3 刻这条线（停在第 8 刻）" [ "$(ticks)" = "8" ]
check "PassWall 只被重启一次" \
	[ "$(restart_count)" = "$((restarts_before + 1))" ]

scenario "14c. 表始终不回来：等满上限才放弃，回滚且退出码 1"
flip_enabled
run_render_timed 1 '' UU_PASSWALL_WAIT=6
check "退出码 1" [ "$rr_rc" = "1" ]
check "调用了 guard restore" grep -qx restore "$GUARD_LOG"
check "没有 commit" sh -c "! grep -qx commit '$GUARD_LOG'"
check "上限是真等满了才放弃（第 6 刻）" [ "$(ticks)" = "6" ]
check "日志点名是等不到表恢复，不是别的失败" grep -q "仍未恢复" "$LOGGER_LOG"

scenario "14d. passwall_wait 是垃圾值：回落默认并告警，绝不静默架空成一秒不等"
# 教训同 uuplugin-scan 的 UU_SWEEP_MAX：非数字会让 [ -lt ] 报错退出 2，而
# while/if 把"报错"读成"条件不成立"，循环一轮都不进——上限被静默架空成 0 秒，
# 比写死 sleep 3 更容易触发误判回滚。这里不照抄 scan 的"拒绝执行"：走到这步
# ACL 已经落盘、guard 已布防，"不执行"没有出口，另一条分支就是整套 restore。
for bad in abc 2k -1 3.5 ' '; do
	flip_enabled
	uci set "uuplugin.main.passwall_wait=$bad"
	run_render_timed 1 8
	check "passwall_wait='$bad'：仍等到第 8 刻（默认 20 生效，没被架空）" \
		[ "$(ticks)" = "8" ]
	check "passwall_wait='$bad'：确认成功而不是回滚" grep -qx commit "$GUARD_LOG"
	check "passwall_wait='$bad'：告警留痕说明回落" grep -q "回落到默认" "$LOGGER_LOG"
done
# 空值不算"写坏了"，它就是没设——照默认值走，且不该告警
flip_enabled
uci set 'uuplugin.main.passwall_wait='
run_render_timed 1 8
check "passwall_wait 为空 = 没设，走默认值 20" [ "$(ticks)" = "8" ]
check "没设不告警（那是没写，不是写坏了）" \
	sh -c "! grep -q '回落到默认' '$LOGGER_LOG'"

scenario "14e. 表很快就回来：立刻往下走，不把上限耗满（证明是轮询不是定长等待）"
flip_enabled
uci set uuplugin.main.passwall_wait=30
run_render_timed 1 2
check "确认成功" grep -qx commit "$GUARD_LOG"
check "只花了 2 刻，没有把 30 秒等满" [ "$(ticks)" = "2" ]

scenario "14f. 表卡在上限那一刻才回来：算成功（检查排在判预算之前，不留缝）"
# 若把循环写成"先判预算再检查"，t=上限 那一次检查就没了，表在最后一秒回来
# 也会被判失败——回滚的代价是停用 uuplugin，不值得为省一次检查冒这个险
flip_enabled
run_render_timed 1 6 UU_PASSWALL_WAIT=6
check "刚好卡线也算成功" grep -qx commit "$GUARD_LOG"
check "没有回滚" sh -c "! grep -qx restore '$GUARD_LOG'"
check "刻度停在 6（上限那一刻仍然检查了一次）" [ "$(ticks)" = "6" ]

scenario "14g. 旧表还没拆完就去看：不许把已经死掉的 PassWall 读成重启成功"
# restart = stop + start，而 stop 是不是同步拆表无法确认（本机找不到 passwall
# 源码，只能按最坏情况设计）。若拆表被甩给后台，restart 刚返回时看到的是还没
# 拆掉的旧表：第一次检查就"成功"→ commit → 清检查点 → 死人开关解除，而代理
# 已经躺下，此后不会再有任何人来收尾。旧代码那句 sleep 3 是顺手挡住了这一幕，
# 换成轮询后必须显式保留：先等旧表消失，再等新表回来。
flip_enabled
run_render_timed 2 '' UU_PASSWALL_WAIT=8
check "旧表拖到第 2 刻才拆掉，没被当成重启成功" \
	sh -c "! grep -qx commit '$GUARD_LOG'"
check "判为失败并回滚" grep -qx restore "$GUARD_LOG"
check "退出码 1" [ "$rr_rc" = "1" ]
check "日志点名是等不到表恢复" grep -q "仍未恢复" "$LOGGER_LOG"

scenario "14h. 默认上限就是 20 秒，不多不少"
# 14d/14e 只能证明"默认值 ≥ 8"——把 PW_WAIT_DEFAULT 从 20 改成 99，那几条断言
# 一条都不会红（变异测试实测过）。默认值是这套等待里唯一一个凭经验拍的数：
# 太小，慢机器继续被误判回滚；太大，PassWall 真死了也要卡满一分多钟才回滚，
# 期间用户是断网的。所以两头都得钉住：14d 从下面钉（第 8 刻必须还在等），
# 这一条从上面钉（第 21 刻必须已经放弃，且刻度恰好停在 20）。
flip_enabled
uci -q delete uuplugin.main.passwall_wait || true
run_render_timed 1 21
check "第 21 刻才回来 → 超出默认上限，判失败" [ "$rr_rc" = "1" ]
check "刻度恰好停在 20（默认值就是 20：19 或 99 都会让这条红）" \
	[ "$(ticks)" = "20" ]
check "走的是等不到表恢复那条出口" grep -q "仍未恢复" "$LOGGER_LOG"
check "回滚了" grep -qx restore "$GUARD_LOG"

scenario "15. 真 guard 的 health：ICMP/HTTP 双探针"
GUARD_REAL="${FILES_DIR}/uuplugin-guard"
check "ICMP 通过即正常" env PING_RC=0 UCF_RC=1 sh "$GUARD_REAL" health
check "ICMP 挂但 HTTP 通过仍算正常" env PING_RC=1 UCF_RC=0 sh "$GUARD_REAL" health
rc=0
env PING_RC=1 UCF_RC=1 sh "$GUARD_REAL" health || rc=$?
check "双双失败才判断网" [ "$rc" = "1" ]

# ---------------------------------------------------------------------------
# 真 guard 的回滚有效性（全部路径打桩，逻辑真跑）
# ---------------------------------------------------------------------------

export UU_GUARD_SELF="$GUARD_REAL"
# UU_GUARD_STATE 在文件开头就导出了（uuplugin.defaults 也要往里写标记）
export UU_GUARD_LOCK="${SANDBOX}/guard.lock"
export UU_CONF_FIREWALL="${SANDBOX}/etc/config/firewall"
export UU_CONF_PASSWALL="${SANDBOX}/etc/config/passwall-file"
export UU_INIT_UUPLUGIN="${SANDBOX}/bin/uu-init-stub"
export UU_INIT_PASSWALL="${SANDBOX}/etc/init.d/passwall"
export UU_INIT_FIREWALL="${SANDBOX}/bin/fw-init-stub"
export UU_FW4="${SANDBOX}/bin/fw4-stub"
export UU_REBOOT="${SANDBOX}/bin/reboot-stub"
export UU_SETSID=""
export UU_GUARD_RETRY_SLEEP=0
export UU_GUARD_REBOOT_DELAY=0

for s in uu-init-stub fw-init-stub fw4-stub reboot-stub; do
	cat >"${SANDBOX}/bin/$s" <<EOF
#!/bin/sh
echo "$s \$*" >>'${SANDBOX}/svc-calls'
exit 0
EOF
	chmod +x "${SANDBOX}/bin/$s"
done
# 引信设长。16/17/17b/17c/18b 这些场景都是自己显式调 restore 的，它们 fork 出
# 来的看门狗**不该**在套件跑完之前醒：设成 1 秒等于每个 protect 都给后面的场景
# 埋一颗 1 秒引信——它醒来会去动共用的 $UU_GUARD_STATE/checkpoint（自检过就
# rm 掉，不过就抢着 restore），把别人正要用的检查点消费掉。真正需要看门狗醒来
# 的只有场景 18，那一场自己临时改小、用完改回。
uci set uuplugin.main.guard_timeout=120
# 上面的 uuplugin.defaults 用例会留下未验证标记；这一段测的是"没有标记时"
# 的基础回滚行为，标记的那一级另有专门场景（18b 起），显式清干净免得串味
rm -f "$UNPROVEN"

scenario "16. 回滚把配置文件真实还原、重载运行时并验证"
mkdir -p "$UU_GUARD_STATE"
printf 'fw GOOD\n' >"$UU_CONF_FIREWALL"
printf 'pw GOOD\n' >"$UU_CONF_PASSWALL"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" protect >/dev/null 2>&1
printf 'fw BROKEN\n' >"$UU_CONF_FIREWALL"
rc=0
env PING_RC=0 sh "$GUARD_REAL" restore >/dev/null 2>&1 || rc=$?
check "restore 退出码 0（自检通过）" [ "$rc" = "0" ]
check "配置文件已还原为检查点内容" grep -q GOOD "$UU_CONF_FIREWALL"
check "运行时已重载（fw4 reload）" grep -q "fw4-stub reload" "${SANDBOX}/svc-calls"
check "uuplugin 已停用" sh -c \
	"grep -q 'uu-init-stub stop' '${SANDBOX}/svc-calls' && grep -q 'uu-init-stub disable' '${SANDBOX}/svc-calls'"
check "检查点已消费（不可重放）" [ ! -d "${UU_GUARD_STATE}/checkpoint" ]

scenario "17. 重启兜底的门控：变更前正常才重启，变更前就断网不重启"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" protect >/dev/null 2>&1
printf 'fw BROKEN2\n' >"$UU_CONF_FIREWALL"
rc=0
env PING_RC=1 UCF_RC=1 sh "$GUARD_REAL" restore >/dev/null 2>&1 || rc=$?
check "自检不过时退出码 1" [ "$rc" = "1" ]
check "配置仍被还原（落盘先于一切）" grep -q GOOD "$UU_CONF_FIREWALL"
check "变更前正常 → 触发重启兜底" grep -q "reboot-stub" "${SANDBOX}/svc-calls"
: >"${SANDBOX}/svc-calls"
env PING_RC=1 UCF_RC=1 sh "$GUARD_REAL" protect >/dev/null 2>&1
env PING_RC=1 UCF_RC=1 sh "$GUARD_REAL" restore >/dev/null 2>&1 || true
rc=0
grep -q "reboot-stub" "${SANDBOX}/svc-calls" && rc=1
check "变更前就断网 → 不重启（防误伤）" [ "$rc" = "0" ]

scenario "17b. 没有检查点可查：该降级的照降，但绝不重启（没有证据就不重启）"
# watch 路径会在没有检查点的情况下升级为 restore。若此时把 health.pre
# 默认成 ok，一次上游断线就走成：自检失败 → 停服务 → 仍失败 → restore
# → 无检查点 → pre=ok → 重启路由器。为运营商抖一下把管理通道自己掐了，
# 正是这套机制承诺过不做的误伤。
rm -rf "${UU_GUARD_STATE}/checkpoint"
: >"${SANDBOX}/svc-calls"
rc=0
env PING_RC=1 UCF_RC=1 sh "$GUARD_REAL" restore >/dev/null 2>&1 || rc=$?
check "退出码 1（确实走完了失败路径，不是提前返回）" [ "$rc" = "1" ]
check "仍然停用了 uuplugin（该做的降级照做）" \
	grep -q "uu-init-stub disable" "${SANDBOX}/svc-calls"
check "但没有重启路由器" sh -c "! grep -q reboot-stub '${SANDBOX}/svc-calls'"

scenario "17c. restore 收显式检查点路径（看门狗跨包升级的保命参数）"
# 包在 grace 窗口内被升级、STATE_DIR 跟着变时，看门狗 exec 到新脚本后
# 若还按新路径找 .active，就会找不到而把配置回滚整段跳过——死人开关
# 失效开门，比没有它更糟。所以 protect/watch 派生时显式传自己那一份。
guard_watchdog_passes_ckpt() { # 两处派生：protect 一处、watch 一处
	[ "$(grep -cF "restore '\$CKPT'" "$GUARD_REAL")" = 2 ]
}
ALT_CKPT="${SANDBOX}/alt-ckpt"
rm -rf "$ALT_CKPT" "${UU_GUARD_STATE}/checkpoint"
mkdir -p "$ALT_CKPT"
printf 'fw GOOD\n' >"$ALT_CKPT/firewall"
echo bad >"$ALT_CKPT/health.pre"
: >"$ALT_CKPT/.active"
printf 'fw BROKEN-ALT\n' >"$UU_CONF_FIREWALL"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" restore "$ALT_CKPT" >/dev/null 2>&1 || true
check "按传入的那一份检查点还原" grep -q GOOD "$UU_CONF_FIREWALL"
check "消费的也是传入的那一份" [ ! -d "$ALT_CKPT" ]
check "派生的看门狗确实传了这个参数（protect 与 watch 各一处）" \
	guard_watchdog_passes_ckpt

scenario "18. 死人开关实弹：调用方死掉，延时校验自动回滚"
# 全套里唯一真等挂钟的一场：延时校验是 guard 自己 fork 出去的，只能等它醒。
# 三处刻意的写法，别改回去：
#   1) 引信只在本场改小。上面那句把它设成了 120，就是不让别的场景的看门狗在
#      套件跑完前醒；本场是唯一真要它醒的，用完立刻改回去。
#   2) 私有的状态目录 + 私有的锁。CKPT 是从 STATE_DIR 派生的，别的场景的看门狗
#      醒来时去动的是共用的 $UU_GUARD_STATE/checkpoint——恰好是本场刚建的那份。
#      谁先把它 mv 走，本场的看门狗醒来就发现 .active 没了、直接 exit 0，于是
#      这两条断言集体红。锁同理：撞上就打"restore 已在进行，跳过"。引信设长
#      已经够了，这两样是第二道保险：路径层面隔离，不靠时序运气。
#   3) 有上限的轮询，不是写死 sleep 3。写死的话机器一忙就假红——而假红的这
#      两条与任何被测改动都无关，变异测试会把它读成"这个变异被抓住了"，
#      假阴性方向恰好是最危险的那侧（本轮真的被这么骗过两次）。
printf 'fw GOOD\n' >"$UU_CONF_FIREWALL"
: >"${SANDBOX}/svc-calls"
uci set uuplugin.main.guard_timeout=1
env PING_RC=1 UCF_RC=1 UU_GUARD_LOCK="${SANDBOX}/guard.lock.18" \
	UU_GUARD_STATE="${SANDBOX}/guard-state-18" \
	sh "$GUARD_REAL" protect >/dev/null 2>&1
uci set uuplugin.main.guard_timeout=120
printf 'fw BROKEN3\n' >"$UU_CONF_FIREWALL"
# 不 commit，模拟调用方死亡；本场引信 1 秒，等延时校验自己醒来
i=0
while [ "$i" -lt 15 ]; do
	if grep -q GOOD "$UU_CONF_FIREWALL" &&
		grep -q "uu-init-stub disable" "${SANDBOX}/svc-calls"; then
		break
	fi
	sleep 1
	i=$((i + 1))
done
# 再等锁自己消失（guard 是 mkdir 取锁、EXIT 时 rmdir）。上面那两个条件只说明
# 回滚走到了第 3 级，看门狗后面还有自检要跑；不等它退干净就进 18b，两个进程
# 会同时改 $UU_CONF_FIREWALL——那是拿一个新竞态换掉旧竞态。
i=0
while [ -d "${SANDBOX}/guard.lock.18" ] && [ "$i" -lt 15 ]; do
	sleep 1
	i=$((i + 1))
done
check "无人确认时配置被自动还原" grep -q GOOD "$UU_CONF_FIREWALL"
check "自动回滚也停用了 uuplugin" grep -q "uu-init-stub disable" "${SANDBOX}/svc-calls"

# ---------------------------------------------------------------------------
# 未验证标记的完整生命周期：uci-defaults 写下 → restore 有权拆 →
# ensure_firewall 证明为好后撤销
#
# 补的是整套回滚里唯一没被检查点覆盖的东西。原时序：uci-defaults 装包时就把
# uu zone 与两条 lan↔uu 转发 commit 进配置，真正生效的 fw4 reload 要等到后来
# ensure_firewall 才发生，于是那时取的检查点里已经躺着这三段。断网后回滚：
# 第 1 级 cmp 判定文件相同 → did_fw=0 → 第 2 级连 fw4 reload 都不做 → 内核里
# 那份有害 ruleset 原样留着 → 第 3 级停服务也拿不掉活在配置文件里的 zone →
# 第 4 级自检失败 → 第 5 级重启 → fw4 从同一份配置重新渲染出同样的 ruleset，
# 而 uuplugin 已 disable、guard 不再布防：问题原样回来且再没有兜底。
# ---------------------------------------------------------------------------

put_fw_sections() { # 把三段放回 uci，模拟 uci-defaults 装完之后的持久配置
	uci set firewall.uu=zone
	uci set firewall.uu.name=uu
	uci set firewall.uu.device='tun*'
	uci set firewall.lan_uu=forwarding
	uci set firewall.lan_uu.src=lan
	uci set firewall.lan_uu.dest=uu
	uci set firewall.uu_lan=forwarding
	uci set firewall.uu_lan.src=uu
	uci set firewall.uu_lan.dest=lan
}
fw4_reloaded() { grep -q "fw4-stub reload" "${SANDBOX}/svc-calls"; }
fw4_not_reloaded() { ! grep -q "fw4-stub reload" "${SANDBOX}/svc-calls"; }

scenario "18b. 检查点里就带着那三段（真实时序）：还原之后还得把它们拆掉"
rm -rf "${UU_GUARD_STATE}/checkpoint"
put_fw_sections
printf 'config zone uu\nconfig forwarding lan_uu\n' >"$UU_CONF_FIREWALL"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" protect >/dev/null 2>&1
: >"$UNPROVEN" # uci-defaults 留下的那个标记
check "前提：检查点与当前配置逐字节相同（第 1 级注定无事可做）" \
	cmp -s "${UU_GUARD_STATE}/checkpoint/firewall" "$UU_CONF_FIREWALL"
env PING_RC=0 sh "$GUARD_REAL" restore >/dev/null 2>&1 || true
check "uu zone 已从持久配置里拆除" uci_missing firewall.uu
check "lan->uu 转发已拆除" uci_missing firewall.lan_uu
check "uu->lan 转发已拆除" uci_missing firewall.uu_lan
check "拆完必须重载内核（否则那份 ruleset 原样留着）" fw4_reloaded
check "标记已消费（下次回滚不再拆一遍别人的配置）" [ ! -f "$UNPROVEN" ]

scenario "18c. 镜像首次开机 / watch 路径：从来没有过检查点，照样得拆"
# 首次开机时 uci-defaults 先跑，/etc/init.d/firewall start 直接把这三段渲染
# 进内核，等 uuplugin 起来 ensure_firewall 在 nft 那一行就短路 return——整条
# 路径上一个检查点都没取过。这一级若写在 `[ -f "$CKPT/.active" ]` 块里面，
# 这里就整段跳过：路由器带着从未被验证过的 ruleset 裸奔，且没有任何兜底。
rm -rf "${UU_GUARD_STATE}/checkpoint"
put_fw_sections
: >"$UNPROVEN"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" restore >/dev/null 2>&1 || true
check "没有检查点也拆掉了 uu zone" uci_missing firewall.uu
check "没有检查点也拆掉了 lan->uu 转发" uci_missing firewall.lan_uu
check "没有检查点也拆掉了 uu->lan 转发" uci_missing firewall.uu_lan
# 这条专钉 did_fw=1：本路径上第 1 级压根没跑，svc-calls 里若有 fw4 reload，
# 只可能是拆段那一级自己触发的。少了它，配置干净了而内核照旧，白拆一场
check "拆段这一级自己就得触发 fw4 reload（此路径上没有别人会触发）" fw4_reloaded
check "标记已消费" [ ! -f "$UNPROVEN" ]

scenario "18d. 没有标记：一个字都不许动用户的防火墙配置"
# ensure_firewall 已经证明这三段无害、撤了标记之后，它们和用户手写的任何
# 一段配置就没有区别了——回滚再去拆，就是拿别人的配置泄愤
rm -rf "${UU_GUARD_STATE}/checkpoint"
put_fw_sections
rm -f "$UNPROVEN"
: >"${SANDBOX}/svc-calls"
env PING_RC=0 sh "$GUARD_REAL" restore >/dev/null 2>&1 || true
check "uu zone 原封不动" uci_is firewall.uu zone
check "lan->uu 转发原封不动" uci_is firewall.lan_uu.dest uu
check "uu->lan 转发原封不动" uci_is firewall.uu_lan.src uu
check "也没有平白无故地重载防火墙" fw4_not_reloaded

scenario "18e. 次序与职责边界：先还原检查点再拆段；guard commit 不碰标记"
# 次序只能静态断言：沙箱里的假 uci 把状态存在 JSON 里，$CONF_FW 只是个被
# cp 来 cp 去的文件，两者不共享内容，"先删后盖会被检查点原样盖回来"这件事
# 在沙箱里复现不出来。真机上它是致命的——cp 覆盖的正是 uci 接着要读的文件。
line_of() { # $1=固定串 -> 在真 guard 里首次出现的行号
	grep -nF "$1" "$GUARD_REAL" | head -1 | cut -d: -f1
}
L_CP=$(line_of 'cp "$CKPT/firewall" "$CONF_FW"')
L_DEL=$(line_of 'uci -q delete firewall.uu')
L_RELOAD=$(line_of '"$FW4" reload')
check "拆段排在还原检查点之后（否则检查点会把刚删的段原样盖回来）" \
	[ "$L_CP" -lt "$L_DEL" ]
check "拆段排在重载运行时之前（否则重载进内核的还是带着三段的那份）" \
	[ "$L_DEL" -lt "$L_RELOAD" ]
# 撤销标记只能由 ensure_firewall 做，绝不能塞进 guard commit：start_service
# 是先 render 后 ensure_firewall，render 成功重启 PassWall 时也会 commit 一次，
# 那会儿 fw4 reload 还没发生，标记被提前清掉，整套兜底当场作废且毫无痕迹
: >"$UNPROVEN"
sh "$GUARD_REAL" commit
check "guard commit 只消费检查点，不撤销未验证标记" [ -f "$UNPROVEN" ]
rm -f "$UNPROVEN"

scenario "18e2. 拆段时 uci commit 落不了盘：保留标记等下次，日志不谎报"
# overlay 满 / 只读时 commit 会失败，那三段仍在 /etc/config/firewall 里。此刻
# 丢掉标记，下一次回滚就再没权限碰它们了——watch 路径的回滚未必走到第 5 级
# 重启，没有"重启后重来一遍"这个后手。日志同理：本仓库反复吃过"报绿其实没
# 干成"的亏（fw4 对解析不到的 zone 只 warn 一句照样退 0），回滚日志更不该是
# 第一个撒谎的人
rm -rf "${UU_GUARD_STATE}/checkpoint"
put_fw_sections
: >"$UNPROVEN"
: >"${SANDBOX}/svc-calls"
: >"${SANDBOX}/guard-msgs"
env PING_RC=0 UCI_REFUSE='^commit firewall$' \
	LOGGER_LOG="${SANDBOX}/guard-msgs" \
	sh "$GUARD_REAL" restore >/dev/null 2>&1 || true
check "commit 没成，标记就留着（下次回滚还能再拆一次）" [ -f "$UNPROVEN" ]
check "不打那句'已拆除'（成功分支独有的原话）" sh -c \
	"! grep -qF '已拆除未经验证' '${SANDBOX}/guard-msgs'"
check "而是照实记一句 commit 失败" sh -c \
	"grep -qF '保留未验证标记待下次回滚重试' '${SANDBOX}/guard-msgs'"
check "内核照样得重载（删除可能已部分落盘，reload 本身无害）" fw4_reloaded
rm -f "$UNPROVEN"

# ---------------------------------------------------------------------------
# uuplugin.init 的 ensure_firewall：全系统唯一撤销未验证标记的地方
# ---------------------------------------------------------------------------

# init 的 shebang 是 `#!/bin/sh /etc/rc.common`，直接跑会缺一堆 rc.common /
# procd 符号。这里 source 真文件（不抄副本——抄出来的会跟着源文件漂移而
# 没有任何人会发现），由 driver 补上 source 期间用得到的那两个符号，
# 再单独调 ensure_firewall。
mkdir -p "${SANDBOX}/libexec"
cp "${SANDBOX}/guard" "${SANDBOX}/libexec/guard"
sed -e "s|/usr/libexec/uuplugin|${SANDBOX}/libexec|" \
	"${FILES_DIR}/uuplugin.init" >"${SANDBOX}/uuplugin.init"
cat >"${SANDBOX}/init-driver" <<EOF
#!/bin/sh
USE_PROCD=1
extra_command() { :; }
. '${SANDBOX}/uuplugin.init'
"\$@"
EOF
chmod +x "${SANDBOX}/init-driver"

# fw4 桩：check 与 reload 的结果分别可控；reload 成功就把 uu 链"渲染进内核"
# （写进 NFT_CHAIN_FILE），因为 ensure_firewall 正是靠 reload 前后那一问判断
# 成败的。FW4_RENDER_UU=0 模拟"reload 返回 0 但链没出来"——转发指向一个解析
# 不到的 zone 时 fw4 只 warn 一句跳过，退出码照样是 0，这正是判据不能取
# reload 退出码的原因。
cat >"${SANDBOX}/bin/fw4" <<EOF
#!/bin/sh
echo "fw4 \$*" >>'${SANDBOX}/fw4-calls'
case "\$1" in
check) exit "\${FW4_CHECK_RC:-0}" ;;
reload)
	[ "\${FW4_RELOAD_RC:-0}" = 0 ] || exit "\${FW4_RELOAD_RC}"
	[ "\${FW4_RENDER_UU:-1}" = 1 ] && echo forward_uu >>'${NFT_CHAIN_FILE}'
	;;
esac
exit 0
EOF
chmod +x "${SANDBOX}/bin/fw4"
: >"${SANDBOX}/fw4-calls"

ensure_fw() { # ensure_fw [VAR=VAL ...] -> rc 写进 $rc
	: >"$GUARD_LOG"
	: >"${SANDBOX}/fw4-calls"
	rc=0
	env "$@" "${SANDBOX}/init-driver" ensure_firewall >/dev/null 2>&1 || rc=$?
}
guard_called() { grep -qx "$1" "$GUARD_LOG"; }
guard_not_called() { ! grep -qx "$1" "$GUARD_LOG"; }
fw4_called() { grep -qx "fw4 $1" "${SANDBOX}/fw4-calls"; }
fw4_not_called() { ! grep -qx "fw4 $1" "${SANDBOX}/fw4-calls"; }

scenario "18f. 短路路径（fw4 启动时就渲染好了）：证明为好才撤掉安全网"
put_fw_sections
echo forward_uu >"$NFT_CHAIN_FILE" # 内核里已经有 uu 链
: >"$UNPROVEN"
ensure_fw
check "退出码 0" [ "$rc" = "0" ]
check "没有 reload（本来就已生效，没有 reload 可做）" fw4_not_called reload
check "但补做了一次出网自检（这条路径此前从未验证过任何东西）" \
	guard_called health
check "自检通过 → 撤除未验证标记" [ ! -f "$UNPROVEN" ]

scenario "18g. 短路路径但出网自检不过：标记必须留着"
# 留着才有下一次机会：restore 拿它当授权去拆那三段。此刻不自己动手拆——
# 断网原因未必是我们，而 restore 那条路有门控、有验证、有重启兜底
: >"$UNPROVEN"
ensure_fw GUARD_HEALTH_RC=1
check "退出码仍是 0（链在内核里，不是本函数该失败的地方）" [ "$rc" = "0" ]
check "自检不过 → 保留未验证标记" [ -f "$UNPROVEN" ]

scenario "18h. 标记已经撤了：短路路径不再白探一次网"
# wan 抖一次就 reload 一次 uuplugin，每次都走这条短路。此时已无标记可撤，
# 白探一遍 ICMP+HTTP 双探针要把 init 挂住十几秒
rm -f "$UNPROVEN"
ensure_fw
check "一个探针都不发" guard_not_called health

scenario "18i. 完整路径：reload 成功且自检通过，才撤掉安全网"
: >"$NFT_CHAIN_FILE" # 内核里还没有 uu 链
: >"$UNPROVEN"
ensure_fw
check "退出码 0" [ "$rc" = "0" ]
check "先渲染校验（check 只渲染不下发）再 reload" sh -c \
	"[ \"\$(head -1 '${SANDBOX}/fw4-calls')\" = 'fw4 check' ]"
check "reload 在 guard 布防之下" guard_called protect
check "走到确认（commit）" guard_called commit
check "成功路径撤除未验证标记" [ ! -f "$UNPROVEN" ]

scenario "18j. reload 之后链没出来：回滚，且绝不撤安全网"
: >"$NFT_CHAIN_FILE"
: >"$UNPROVEN"
ensure_fw FW4_RENDER_UU=0
check "退出码 1" [ "$rc" = "1" ]
check "调了 restore 回滚" guard_called restore
check "没有确认（无 commit）" guard_not_called commit
check "失败路径保留未验证标记（restore 全指着它才敢拆那三段）" \
	[ -f "$UNPROVEN" ]

scenario "18k. fw4 check 不过：不碰运行时，也不动标记"
: >"$NFT_CHAIN_FILE"
: >"$UNPROVEN"
ensure_fw FW4_CHECK_RC=1
check "退出码 1" [ "$rc" = "1" ]
check "没有 reload" fw4_not_called reload
check "连布防都没有（根本没碰运行时，无需回滚）" guard_not_called protect
check "标记留着" [ -f "$UNPROVEN" ]

scenario "18m. 连 uu zone 都不在（uci-defaults 没跑成）：直接退，不动标记"
uci delete firewall.uu
: >"$UNPROVEN"
ensure_fw
check "退出码 1" [ "$rc" = "1" ]
check "没做任何自检" guard_not_called health
check "标记留着" [ -f "$UNPROVEN" ]
rm -f "$UNPROVEN"

scenario "18n. .active 在而 health.pre 读不到：按无证据处理，绝不重启"
# 这条窄路真实存在：protect 先写 health.pre（3 字节）再建 .active（0 字节），
# overlay 写满时前者可能失败而后者照样建出来——16MB 的 overlay 写满并不稀奇。
# 此时把 pre 回落成 ok，等于"证据丢了就当证据是好的"：回滚验证失败会直接
# 走到重启兜底。手工搭检查点、不经 protect（免得 fork 出看门狗）；私有状态
# 目录 + 私有锁 + 显式传检查点路径，一个字都不碰 16 以来共用的那两份。
CKPT_18N="${SANDBOX}/guard-state-18n/checkpoint"
mkdir -p "$CKPT_18N"
: >"$CKPT_18N/.active" # 只有 .active，刻意不放 health.pre
: >"${SANDBOX}/svc-calls"
: >"${SANDBOX}/guard-msgs-18n"
rc=0
env PING_RC=1 UCF_RC=1 UU_GUARD_RETRY_SLEEP=0 \
	UU_GUARD_STATE="${SANDBOX}/guard-state-18n" \
	UU_GUARD_LOCK="${SANDBOX}/guard.lock.18n" \
	LOGGER_LOG="${SANDBOX}/guard-msgs-18n" \
	sh "$GUARD_REAL" restore "$CKPT_18N" >/dev/null 2>&1 || rc=$?
check "退出码 1（走完了失败路径，不是提前返回）" [ "$rc" = "1" ]
check "没有重启路由器" sh -c "! grep -q reboot-stub '${SANDBOX}/svc-calls'"
check "日志照实记了自检失败" sh -c \
	"grep -qF '回滚后出网自检仍失败' '${SANDBOX}/guard-msgs-18n'"
check "没打重启那句（重启分支独有的原话）" sh -c \
	"! grep -qF '后重启路由器' '${SANDBOX}/guard-msgs-18n'"

# ---------------------------------------------------------------------------
# 主动扫描：按 lan 的真实前缀长度枚举，而不是假设 /24
# ---------------------------------------------------------------------------

PING_LOG="${SANDBOX}/ping-log"
SWEEP_OUT="${SANDBOX}/sweep-out"

run_sweep() { # run_sweep <子网> [额外的 VAR=VAL ...]
	local subnet="$1"
	shift
	: >"$PING_LOG"
	env PING_LOG="$PING_LOG" UU_LAN_SUBNET="$subnet" "$@" \
		"${SANDBOX}/uu-scan" sweep >"$SWEEP_OUT" 2>&1
}
ping_count() { wc -l <"$PING_LOG" | tr -d ' '; }
pinged() { grep -qxF "$1" "$PING_LOG"; }
not_pinged() { ! grep -qxF "$1" "$PING_LOG"; }

scenario "19. sweep 在 /24 上的行为（与旧实现等价，防回归）"
run_sweep 192.168.7.1/24
check "扫 254 个地址" [ "$(ping_count)" = 254 ]
check "从 .1 开始" pinged 192.168.7.1
check "到 .254 结束" pinged 192.168.7.254
check "不碰网络地址 .0" not_pinged 192.168.7.0
check "不碰广播地址 .255" not_pinged 192.168.7.255

scenario "19b. /23：接口地址要先掩成网络地址，且跨字节进位"
# network_get_subnet 给的是接口地址（192.168.7.1/23），不是网络地址；
# 旧实现直接 cut 前三段当 base，在这里会漏掉整个 192.168.6.0/24 半区
run_sweep 192.168.7.1/23
check "扫 510 个地址" [ "$(ping_count)" = 510 ]
check "掩到 192.168.6.0：下半区也扫" pinged 192.168.6.1
check "跨第三字节进位正确" pinged 192.168.7.1
check "扫到末地址 192.168.7.254" pinged 192.168.7.254
check "不碰网络地址 192.168.6.0" not_pinged 192.168.6.0
check "不碰广播地址 192.168.7.255" not_pinged 192.168.7.255
check "不越界到 192.168.8.x" sh -c "! grep -q '^192\.168\.8\.' '$PING_LOG'"

scenario "19c. /25：只扫本半区，不把邻居子网也扫了"
run_sweep 192.168.7.130/25
check "扫 126 个地址" [ "$(ping_count)" = 126 ]
check "起点 .129" pinged 192.168.7.129
check "终点 .254" pinged 192.168.7.254
check "不越到下半区（.126 是别人的地址）" not_pinged 192.168.7.126
check "不碰网络地址 .128" not_pinged 192.168.7.128

scenario "19d. 高位网段：整数化 IP 会溢出成负数的那一类"
run_sweep 240.10.20.200/26
check "扫 62 个地址" [ "$(ping_count)" = 62 ]
check "掩到 240.10.20.192" pinged 240.10.20.193
check "终点 .254" pinged 240.10.20.254
check "不碰广播地址 .255" not_pinged 240.10.20.255

scenario "19e. /31 /32：没有网络/广播地址的特例"
run_sweep 10.9.9.9/32
check "/32 只扫它自己" [ "$(ping_count)" = 1 ]
check "扫的就是 10.9.9.9" pinged 10.9.9.9
run_sweep 10.9.9.8/31
check "/31 扫两个地址" [ "$(ping_count)" = 2 ]
check "/31 含网络地址本身" pinged 10.9.9.8

scenario "19f. 网段过大：明确拒绝并指路，绝不静默只扫一部分"
run_sweep 10.0.0.1/16
check "一个都不 ping" [ "$(ping_count)" = 0 ]
check "说明是超上限跳过" grep -q "超过上限" "$SWEEP_OUT"
check "报出算出来的地址数 65534" grep -q 65534 "$SWEEP_OUT"
check "指路差分识别" grep -q "service uuplugin watch" "$SWEEP_OUT"
check "仍然列出当前邻居表（不是干脆不干活）" \
	grep -q "候选设备加入加速" "$SWEEP_OUT"

scenario "19g. 上限是真比较，不是写死的某个前缀长度"
run_sweep 192.168.7.1/24 UU_SWEEP_MAX=253
check "254 > 253：拒绝" [ "$(ping_count)" = 0 ]
run_sweep 192.168.7.1/24 UU_SWEEP_MAX=254
check "254 = 254：放行（边界含等号）" [ "$(ping_count)" = 254 ]
# 默认上限是 510（一个 /23）。见脚本头部：再大不只是费时间，还会把内核
# 邻居表顶穿——扫描给每个不存在的地址留一条 FAILED 表项，而默认
# gc_thresh3=1024。为找一台游戏机把全网抖一下，不划算。
run_sweep 10.1.4.9/23
check "默认上限放行一整个 /23（510 个）" [ "$(ping_count)" = 510 ]
run_sweep 10.1.4.9/22
check "默认上限拦下 /22（1022 个）" [ "$(ping_count)" = 0 ]
check "拒绝时把确切的抬法写给人看" grep -q "UU_SWEEP_MAX=1022" "$SWEEP_OUT"
# 上一条印出来的抬法不能是空头支票
run_sweep 10.1.4.9/22 UU_SWEEP_MAX=1022
check "照它说的抬到 1022 就真能扫满" [ "$(ping_count)" = 1022 ]
check "/22 掩到 10.1.4.0" pinged 10.1.4.1
check "/22 扫到 10.1.7.254" pinged 10.1.7.254

scenario "19h. 子网信息不可用或畸形：跳过扫描但照常出清单"
run_sweep ''
check "取不到子网：不 ping" [ "$(ping_count)" = 0 ]
check "取不到子网：说明原因" grep -q "取不到 lan 子网" "$SWEEP_OUT"
check "取不到子网：仍出清单" grep -q "候选设备加入加速" "$SWEEP_OUT"
run_sweep 192.168.7.1/abc
check "前缀长度非数字：不 ping" [ "$(ping_count)" = 0 ]
check "前缀长度非数字：说明原因" grep -q "读不出来" "$SWEEP_OUT"
run_sweep 192.168.7.1/64
check "前缀长度越界：不 ping" [ "$(ping_count)" = 0 ]
check "前缀长度越界：说明原因" grep -q "越界" "$SWEEP_OUT"

scenario "19i. 上限本身不是数：拒绝在上限不明的情况下开扫"
# [ -gt ] 拿到非数字会报错退出 2，而 if 把"报错"读成"条件不成立"——
# 上限于是被静默架空：UU_SWEEP_MAX=2k 会老老实实把 /20 的 4094 个地址
# 全扫完；0x400 更糟，只扫 1025 个就当扫完了整个 /8。
for bad in 2k 0x400 abc -1 ' '; do
	run_sweep 10.1.4.9/22 "UU_SWEEP_MAX=$bad" || true
	check "UU_SWEEP_MAX='$bad'：一个都不 ping" [ "$(ping_count)" = 0 ]
	check "UU_SWEEP_MAX='$bad'：说明上限不合法" \
		grep -q "不是非负整数" "$SWEEP_OUT"
done
# 空值不算"写坏了"，它就是没设——照默认值走
run_sweep 192.168.7.1/24 UU_SWEEP_MAX=
check "UU_SWEEP_MAX 为空 = 没设，走默认值" [ "$(ping_count)" = 254 ]

scenario "19j. 子网的地址一侧畸形：同样拒绝，绝不 ping 出一串假地址"
# 前缀查得再严，"1.2.3.4.5/26" 照样能走到下面去 ping 62 个字面量叫
# "...1"、"...2" 的东西，还打印一行"共 62 个地址"当成功报出去。
# 前导零单列：$(( 09 )) 会被当八进制解析而报错，报错在 $( ) 里只剩空串。
for bad in 1.2.3.4.5/26 192.168.7.256/24 192.168.07.1/24 abc.def.ghi.jkl/24; do
	run_sweep "$bad"
	# 一律写 ${bad}：紧跟其后的是全角冒号，某些 shell 会把它当成变量名的
	# 一部分去查（于是 set -u 直接判"未定义"把整个套件炸掉）
	check "${bad}：一个都不 ping" [ "$(ping_count)" = 0 ]
	check "${bad}：说明地址不合法" grep -q "不是合法 IPv4" "$SWEEP_OUT"
done

scenario "19k. 大网段：地址数要算准；真算不出就明说，绝不编个数字冒充"
run_sweep 10.0.0.1/12
check "/12 报 1048574" grep -q 1048574 "$SWEEP_OUT"
run_sweep 10.0.0.1/8
check "/8 报 16777214" grep -q 16777214 "$SWEEP_OUT"
run_sweep 10.0.0.1/2
check "/2 仍算得出（h=30 是含边界）" grep -q 1073741822 "$SWEEP_OUT"
# 2^31 在 32 位有符号里翻成负数，/1 与 /0 一律判为"算不出"。若这里编个
# 哨兵值冒充规模，"超过上限 510"就会读起来像"把上限抬一点就能扫"，
# 而实际差着六个数量级。
run_sweep 10.0.0.1/1
check "/1：一个都不 ping" [ "$(ping_count)" = 0 ]
check "/1：明说算不出，而不是报一个假数" \
	grep -q "大到无法逐个枚举" "$SWEEP_OUT"
check "/1：不走'超过上限'那句（那句会误导人去抬上限）" \
	sh -c "! grep -q '超过上限' '$SWEEP_OUT'"
check "/1：照样指路差分识别" grep -q "service uuplugin watch" "$SWEEP_OUT"
run_sweep 0.0.0.0/0
check "/0：一个都不 ping" [ "$(ping_count)" = 0 ]
check "/0：明说算不出" grep -q "大到无法逐个枚举" "$SWEEP_OUT"

scenario "19m. 不喂 UU_LAN_SUBNET 时，网段是真去问了系统"
# 绊网：把 resolve_subnet 的调用整个删掉，上面所有 sweep 用例照样全绿——
# 它们都显式喂了 UU_LAN_SUBNET。这一条不喂，逼脚本去问 netifd。
NET_LOG="${SANDBOX}/net-log"
: >"$PING_LOG"
: >"$NET_LOG"
env -u UU_LAN_SUBNET PING_LOG="$PING_LOG" NET_LOG="$NET_LOG" \
	FAKE_LAN_SUBNET=172.31.9.5/28 \
	"${SANDBOX}/uu-scan" sweep >"$SWEEP_OUT" 2>&1
check "问的是 lan 接口的子网" grep -qx "network_get_subnet lan" "$NET_LOG"
check "按系统给的 /28 扫 14 个地址" [ "$(ping_count)" = 14 ]
check "掩到 172.31.9.0（系统给的是接口地址 .5，不是网络地址）" \
	pinged 172.31.9.1
check "终点 172.31.9.14" pinged 172.31.9.14
check "不碰广播地址 172.31.9.15" not_pinged 172.31.9.15
# 系统也答不上来时老实说，不是拿个默认网段瞎扫
: >"$PING_LOG"
env -u UU_LAN_SUBNET PING_LOG="$PING_LOG" \
	"${SANDBOX}/uu-scan" sweep >"$SWEEP_OUT" 2>&1
check "系统也给不出时：一个都不 ping" [ "$(ping_count)" = 0 ]
check "系统也给不出时：说明取不到" grep -q "取不到 lan 子网" "$SWEEP_OUT"

# ---------------------------------------------------------------------------
# 租约文件候选表：UCI 里 dnsmasq 的 leasefile ∪ 三条内置路径
# ---------------------------------------------------------------------------

# 这批场景要走候选表机制，逐次 env -u UU_LEASES（套件其余场景全靠这个
# 环境变量保持既有行为——它设着时候选表整个跳过）。内置三条已被上面的
# sed 指进 $BL_DIR。
CT_OUT="${SANDBOX}/ct-out"
SCAN_ERR="${SANDBOX}/scan-err"
run_ct() { # -> rc；list 输出进 CT_OUT，stderr 进 SCAN_ERR
	rc=0
	env -u UU_LEASES "${SANDBOX}/uu-scan" list >"$CT_OUT" 2>"$SCAN_ERR" || rc=$?
}
ct_has() { grep -q "$1" "$CT_OUT"; }
ct_lacks() { ! grep -q "$1" "$CT_OUT"; }
# 发布文件里的三条真实路径（沙箱副本被 sed 换过，只能钉发布文件）。
# 把续行折成单行再整串比对：三条一条不能少、次序与前后件也不能漂
builtin_triple_present() {
	tr -s '\\\n\t ' ' ' <"${FILES_DIR}/uuplugin-scan" |
		grep -qF '/tmp/dhcp.leases /var/lib/misc/dnsmasq.leases /tmp/var/lib/misc/dnsmasq.leases'
}
# odhcpd 与 ISC dhcpd 的路径只许出现在注释里当反例：它们的落盘格式喂进
# gather 的 awk 只吐垃圾行，autoadd=1 时垃圾 MAC 会进 PassWall ACL
no_foreign_lease_sources() {
	! grep -v '^[[:space:]]*#' "${FILES_DIR}/uuplugin-scan" |
		grep -Eq 'odhcpd|/etc/config/dhcpd\.leases'
}

scenario "23a. 候选表：UCI 自定义 leasefile（stock 的匿名 @dnsmasq[0] 形态）被读到"
LF1="${SANDBOX}/dnsmasq-a.leases"
printf '1734567890 aa:bb:cc:00:00:01 10.0.0.1 host-a *\n' >"$LF1"
D=$(uci add dhcp dnsmasq) # stock 的 /etc/config/dhcp 里 dnsmasq 就是匿名段
uci set "dhcp.${D}.leasefile=${LF1}"
check "沙箱确实产出了匿名 dnsmasq 形态" sh -c \
	"uci show dhcp | grep -qx 'dhcp.@dnsmasq\[0\]=dnsmasq'"
run_ct
check "退出码 0" [ "$rc" = 0 ]
check "读到自定义 leasefile 里的设备" ct_has 'aa:bb:cc:00:00:01'
check "主机名也带出来了" ct_has 'host-a'
# @dnsmasq[0] 的 [] 是合法通配符，遍历必须关 glob——沿用 10i 的陷阱目录
: >"${GLOBDIR}/@dnsmasq0"
rc=0
(cd "$GLOBDIR" && env -u UU_LEASES "${SANDBOX}/uu-scan" list) \
	>"$CT_OUT" 2>"$SCAN_ERR" || rc=$?
check "当前目录有 @dnsmasq0 也照样认得出匿名段" ct_has 'aa:bb:cc:00:00:01'
check "发布文件里三条内置候选路径逐字在位" builtin_triple_present
check "代码行不含 odhcpd / ISC dhcpd 的租约路径（只许在注释里当反例）" \
	no_foreign_lease_sources

scenario "23b. 两个 dnsmasq 实例：两份 leasefile 都读，跨文件重复 MAC 先读到的赢"
LF2="${SANDBOX}/dnsmasq-b.leases"
printf '1734567891 aa:bb:cc:00:00:01 10.0.9.9 dupe-host *\n' >"$LF2"
printf '1734567892 aa:bb:cc:00:00:02 10.0.0.2 host-b *\n' >>"$LF2"
D=$(uci add dhcp dnsmasq)
uci set "dhcp.${D}.leasefile=${LF2}"
run_ct
check "第二个实例独有的设备也读到" ct_has 'aa:bb:cc:00:00:02'
check "跨文件重复 MAC 只出现一次" sh -c \
	"[ \$(grep -c 'aa:bb:cc:00:00:01' '$CT_OUT') -eq 1 ]"
check "先读到的赢：保留第一份的主机名" ct_has 'host-a'
check "后读到的重复行被丢：它的主机名不出现" ct_lacks 'dupe-host'

scenario "23c. odhcpd 的 leasefile：候选表里根本没有它（按 section 类型排除）"
# 文件内容故意做成能通过 gather 格式守门的样子：若它被错误地纳入候选，
# 这台"设备"就会出现在清单里。断言的是"没被打开"，不是"打开了但被滤掉"。
ODH="${SANDBOX}/odhcpd.leases"
printf '1734567893 ee:ee:ee:00:00:03 10.9.9.9 odhcpd-victim *\n' >"$ODH"
uci set dhcp.odhcpd=odhcpd # stock 形态：config odhcpd 'odhcpd'
uci set "dhcp.odhcpd.leasefile=${ODH}"
run_ct
check "odhcpd 指向的文件一行都不进结果" ct_lacks 'ee:ee:ee:00:00:03'
check "dnsmasq 的候选不受影响" ct_has 'aa:bb:cc:00:00:01'

scenario "23d. UU_LEASES 显式设置：只读它，候选表一概不读"
printf '1734567894 dd:dd:dd:00:00:04 10.0.0.4 explicit *\n' >"$UU_LEASES"
rc=0
"${SANDBOX}/uu-scan" list >"$CT_OUT" 2>"$SCAN_ERR" || rc=$? # UU_LEASES 导出着
check "读到显式指定文件里的设备" ct_has 'dd:dd:dd:00:00:04'
check "UCI 候选一概不读（第一份）" ct_lacks 'aa:bb:cc:00:00:01'
check "UCI 候选一概不读（第二份）" ct_lacks 'aa:bb:cc:00:00:02'
: >"$UU_LEASES"

scenario "23e. ISC dhcpd 格式误入候选：格式守门丢掉每一行，零垃圾输出"
# 用户把某个 dnsmasq 的 leasefile 指到一份 ISC 文件时走到这里。ISC 是多行
# 花括号语法，喂进按五字段取 $2/$3/$4 的 awk 不报错、只吐垃圾——而
# autoadd=1 时垃圾 MAC 会被 render 一路写进 PassWall ACL 的 sources
ISC="${SANDBOX}/isc.leases"
cat >"$ISC" <<'EOF'
lease 192.168.1.5 {
  starts 4 2026/08/25 10:00:00;
  hardware ethernet aa:bb:cc:dd:ee:99;
  client-hostname "x";
}
EOF
D=$(uci add dhcp dnsmasq)
uci set "dhcp.${D}.leasefile=${ISC}"
run_ct
check "退出码 0" [ "$rc" = 0 ]
check "ISC 的 IP 字面量没漏进来" ct_lacks '192\.168\.1\.5'
check "ISC 的 MAC 字面量没漏进来" ct_lacks 'aa:bb:cc:dd:ee:99'
check "花括号等语法碎片没漏进来" sh -c "! grep -qF '{' '$CT_OUT'"
check "合法候选照常读" ct_has 'aa:bb:cc:00:00:01'
# 守门的另一边不能误杀：到期秒=0 是 dnsmasq 写永久租约的方式，合法
printf '0 aa:bb:cc:00:00:05 10.0.0.5 forever *\n' >>"$LF1"
run_ct
check "0 到期的永久租约合法放行" ct_has 'aa:bb:cc:00:00:05'

scenario "23f. 非法路径跳过并 warn；没有任何 UCI leasefile 时内置三条兜底"
# 摘掉全部合法 leasefile，换上两条非法的（相对路径、含空格）
for s in $(uci -q _sections dhcp dnsmasq); do
	uci -q delete "dhcp.${s}.leasefile" || true
done
D=$(uci add dhcp dnsmasq)
uci set "dhcp.${D}.leasefile=relative/path.leases"
D=$(uci add dhcp dnsmasq)
uci set "dhcp.${D}.leasefile=/tmp/leases with space"
# 内置三条（已被 sed 指进沙箱）各放一台设备
printf '1734567895 bb:bb:bb:00:00:11 10.1.0.1 builtin-one *\n' \
	>"${BL_DIR}/dhcp.leases"
printf '1734567896 bb:bb:bb:00:00:12 10.1.0.2 builtin-two *\n' \
	>"${BL_DIR}/var-dnsmasq.leases"
printf '1734567897 bb:bb:bb:00:00:13 10.1.0.3 builtin-three *\n' \
	>"${BL_DIR}/tmpvar-dnsmasq.leases"
run_ct
check "退出码 0（一条写坏的 leasefile 不把清单整个打死）" [ "$rc" = 0 ]
check "相对路径：stderr 有 warn" sh -c "grep -q '相对路径' '$SCAN_ERR'"
check "含空格路径：stderr 有 warn" sh -c "grep -q '非常规字符' '$SCAN_ERR'"
check "内置候选一（/tmp/dhcp.leases 位）生效" ct_has 'bb:bb:bb:00:00:11'
check "内置候选二（/var/lib/misc 位）生效" ct_has 'bb:bb:bb:00:00:12'
check "内置候选三（/tmp/var/lib/misc 位）生效" ct_has 'bb:bb:bb:00:00:13'
# 收尾：拆光 dhcp 配置、清空内置位，别影响后面的场景
for s in $(uci -q _sections dhcp dnsmasq); do uci delete "dhcp.${s}"; done
uci delete dhcp.odhcpd
rm -f "${BL_DIR}/dhcp.leases" "${BL_DIR}/var-dnsmasq.leases" \
	"${BL_DIR}/tmpvar-dnsmasq.leases"

# ---------------------------------------------------------------------------
# 主机名特征表
# ---------------------------------------------------------------------------

scenario "20. 主机名特征表：文件驱动、缺失兜底、清空即关闭"
HINTS="${SANDBOX}/hostname-hints"
list_tag() { # $1=主机名 -> 该设备在清单里的判定列
	printf '1734567899 02:00:00:aa:bb:cc 10.0.0.9 %s *\n' "$1" >"$UU_LEASES"
	"${SANDBOX}/uu-scan" list 2>/dev/null |
		awk '$1=="02:00:00:aa:bb:cc"{print $4}'
}
# 按 load_hints 的拼法把数据文件折成一条正则，用来和脚本里的内置兜底比对
hints_joined() {
	sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^#.*//' \
		-e 's/^|*//' -e 's/|*$//' "$1" |
		grep -v '^$' | tr '\n' '|' | sed 's/|$//'
}
export UU_HINT_FILE="$HINTS"

printf 'playstation\n# 注释\n\n   \n' >"$HINTS"
check "命中表里的规则" [ "$(list_tag my-playstation-5)" = 主机名特征 ]
check "表外的主机名不误报" [ "$(list_tag some-laptop)" = — ]
check "注释与空行没变成'匹配一切'的空正则" [ "$(list_tag zzz)" = — ]
check "内置规则此时不生效（表说了算）" [ "$(list_tag nintendo-switch)" = — ]

: >"$HINTS"
check "清空表 = 关掉主机名判定，而不是退化成匹配一切" \
	[ "$(list_tag nintendo-switch)" = — ]

rm -f "$HINTS"
check "表缺失（没装/被删）时回落到内置规则" \
	[ "$(list_tag nintendo-switch)" = 主机名特征 ]

export UU_HINT_FILE="${FILES_DIR}/hostname-hints"
check "随包发布的表认得 Switch" [ "$(list_tag Nintendo-Switch)" = 主机名特征 ]
check "随包发布的表认得 NX 代号" [ "$(list_tag my-nx-box)" = 主机名特征 ]
check "随包发布的表不误伤 nxlog" [ "$(list_tag nxlog-server)" = — ]
check "随包发布的表不误伤 lynx" [ "$(list_tag lynx-browser)" = — ]
FILE_RE=$(hints_joined "${FILES_DIR}/hostname-hints")
BUILTIN_RE=$(sed -n "s/^HINT_BUILTIN='\(.*\)'\$/\1/p" "${FILES_DIR}/uuplugin-scan")
check "随包发布的表与内置兜底逐字一致（避免两套规则漂移）" \
	[ "$FILE_RE" = "$BUILTIN_RE" ]

scenario "20b. 特征表写坏了：宁可关掉主机名判定，也不放行一条匹配一切的规则"
export UU_HINT_FILE="$HINTS"
hint_warned() { # $1=期望在警告里出现的字样
	printf '1734567899 02:00:00:aa:bb:cc 10.0.0.9 whatever *\n' >"$UU_LEASES"
	"${SANDBOX}/uu-scan" list 2>&1 >/dev/null | grep -q "$1"
}
# 行首/行尾多余的 | 是最常见的手滑（"switch|" + "nintendo" 会拼出
# "switch||nintendo"）。空分支匹配空串，也就是匹配任何主机名——autoadd=1
# 时那意味着全网设备一起脱离 PassWall。这种能自动看懂的，按用户的本意修。
printf 'switch|\n|nintendo\n' >"$HINTS"
check "两端多余的 | 被削掉，规则照常生效" \
	[ "$(list_tag my-switch-2)" = 主机名特征 ]
check "削完不会把无关主机名也标上" [ "$(list_tag some-laptop)" = — ]
# 行内的空分支看不出本意（到底想写 a|b 还是 ab？），一律停用并吵出来
printf 'switch||nintendo\n' >"$HINTS"
check "行内空分支：整表停用，不匹配一切" [ "$(list_tag some-laptop)" = — ]
check "行内空分支：连本该命中的也不认（确实是停用，不是碰巧）" \
	[ "$(list_tag nintendo-switch)" = — ]
# 断言必须落在结构检查独有的那句话上。只查"停用主机名判定"是句摆设：
# 后面那道非法正则探针停用时印的也是这五个字，而本机的 grep（ugrep）恰好
# 把 a||b 判成非法正则——于是把结构检查整段删掉，测试照样全绿。
# BusyBox 的 grep 不这么认为：它会痛快地拿 a||b 去匹配一切。
check "行内空分支：明说是空分支停用的（不是被正则探针顺手挡下的）" \
	hint_warned '空的正则分支'
# 正则本身写坏了（漏括号之类）：不修，但必须吵出来——否则表面上一台都
# 认不出，看不出是规则坏了还是真没有游戏机
printf 'switch(\n' >"$HINTS"
check "非法正则：不匹配任何主机名" [ "$(list_tag my-switch)" = — ]
check "非法正则：明说不是合法正则" hint_warned '不是合法的正则'
# 以 - 开头的行不能被 grep 当成选项吞掉（-i 会让 grep 报"非法用法"）
printf -- '-switch\n' >"$HINTS"
check "以 - 开头的规则不被当成 grep 选项" \
	[ "$(list_tag my-switch)" = 主机名特征 ]
# 文件在但读不了（权限改坏）要和"没装"走同一条路回落到内置兜底，
# 不能因为 sed 读失败就把 HINT_RE 留空、悄悄关掉主机名判定
printf 'playstation\n' >"$HINTS"
chmod 000 "$HINTS"
if [ -r "$HINTS" ]; then # root 跑测试时 chmod 000 拦不住，跳过而不是假绿
	printf '  --  跳过"不可读"用例（当前用户能无视文件权限）\n'
else
	check "表存在但读不了：回落到内置规则，而不是静默关掉判定" \
		[ "$(list_tag nintendo-switch)" = 主机名特征 ]
	check "回落后不受那份读不到的表影响" [ "$(list_tag my-playstation)" = — ]
fi
chmod 644 "$HINTS"

scenario "20c. 特征表只读一次：警告不按设备台数刷屏"
# classify 跑在 $( ) 子进程里，memoization 不做在父进程就等于没做——
# 一份写坏的表会按局域网设备台数把同一句警告刷出来
printf 'a||b\n' >"$HINTS"
: >"$UU_LEASES"
for i in 1 2 3 4 5; do
	printf '1734567899 02:00:00:aa:bb:0%s 10.0.0.%s host%s *\n' "$i" "$i" "$i" \
		>>"$UU_LEASES"
done
# || true 不能省：一条都没匹配上时 grep -c 打印 0 但退出 1，而本文件开了
# set -e，`var=$(...)` 这种整条命令就是赋值的形式会照单全收那个 1，套件当场
# 中断在这里、连"结果：N 通过"都印不出来。变异测试的夹具只解析那一行，于是
# 把"套件崩了"读成"全绿"——恰好是最危险的方向：变异明明被抓住了却报没抓住。
warn_lines=$("${SANDBOX}/uu-scan" list 2>&1 >/dev/null | grep -c '空的正则分支' || true)
check "5 台设备只警告一次" [ "$warn_lines" = "1" ]
rm -f "$HINTS"
: >"$UU_LEASES"

scenario "20d. 语法合法但匹配一切的规则：双哨兵探针，同样整表停用"
export UU_HINT_FILE="$HINTS"
hint_not_warned() { ! hint_warned "$1"; }
# 前两道闸（削两端的 | 、查行内 || 、查语法合法性）看的都是"写法"，而一行
# 只写 "." 的规则写法上跟 "switch" 毫无分别，却匹配任何主机名：classify 给
# 每台有主机名的设备打上"主机名特征" → autoadd=1 时 cmd_auto 逐台写 device
# 段 → render 把它们的 MAC 全塞进 PassWall ACL 的 sources → 全网设备一起
# 脱离 PassWall。语法上分不出来，就只能拿哨兵串实测。
for bad in '.' '.*' '^' '$' '[a-z0-9]'; do
	printf '%s\n' "$bad" >"$HINTS"
	check "通配规则 [${bad}]：不匹配任何主机名" [ "$(list_tag some-laptop)" = — ]
	check "通配规则 [${bad}]：连本该命中的也不认（确实是停用，不是碰巧）" \
		[ "$(list_tag nintendo-switch)" = — ]
	check "通配规则 [${bad}]：明说是通配规则停用的" hint_warned '通配规则'
done
# 断言必须钉在这道闸独有的字样上。"停用主机名判定"三道闸都会印，"匹配任意
# 主机名"空分支那道也印——只查这些等于没查：整段删掉探针，测试照样全绿。
printf '.\n' >"$HINTS"
check "通配警告不蹭空分支闸的措辞" hint_not_warned '空的正则分支'
check "通配警告不蹭非法正则闸的措辞" hint_not_warned '不是合法的正则'
# 双哨兵不是钝锤：一串纯字母、一串纯数字，正是为了放过"宽但仍挑字符类"的
# 规则——它们各只命中一串。整表停用是很重的处置，够不着就别下手。
# 这两条同时也是"两串哨兵一个都不能少"的绊网：只留字母串，[a-z] 那条会红；
# 只留数字串，[0-9] 那条会红。
printf '[0-9]\n' >"$HINTS"
check "过宽但不通配的 [0-9]：照常判定，不被停用" \
	[ "$(list_tag host-42)" = 主机名特征 ]
check "过宽但不通配的 [0-9]：不报通配警告" hint_not_warned '通配规则'
printf '[a-z]\n' >"$HINTS"
check "过宽但不通配的 [a-z]：照常判定，不被停用" \
	[ "$(list_tag some-laptop)" = 主机名特征 ]
check "过宽但不通配的 [a-z]：不报通配警告" hint_not_warned '通配规则'
# 判定用的是 grep -i，探针不带 -i 就漏掉这种：[A-Z0-9] 在忽略大小写下照样
# 匹配一切，而不忽略时只有数字哨兵命中，直接放行
printf '[A-Z0-9]\n' >"$HINTS"
check "大写写法的通配 [A-Z0-9]：一样停用（探针与判定同样忽略大小写）" \
	[ "$(list_tag some-laptop)" = — ]
check "大写写法的通配 [A-Z0-9]：明说是通配规则停用的" hint_warned '通配规则'
# 表的第一个字符是 - 时，探针的 -- 不能丢：丢了 grep 会把 "-|." 整个当成
# 选项串，探测本身报错退出，这道闸静默失效（而 host_hint 那边带着 --，
# 表照常匹配一切，坏得完全看不出来）
printf -- '-\n.\n' >"$HINTS"
check "以 - 开头的通配表：照样停用（没把表当成 grep 的选项）" \
	[ "$(list_tag some-laptop)" = — ]
check "以 - 开头的通配表：明说是通配规则停用的" hint_warned '通配规则'
# 防呆闸最要紧的一条：不许误伤正常的表。哨兵串必须撞不上任何一条真规则
printf 'switch\nnintendo\n' >"$HINTS"
check "正常表：命中照常" [ "$(list_tag nintendo-switch)" = 主机名特征 ]
check "正常表：不误报" [ "$(list_tag some-laptop)" = — ]
check "正常表：不报通配警告" hint_not_warned '通配规则'
export UU_HINT_FILE="${FILES_DIR}/hostname-hints"
check "随包发布的默认表：不报通配警告（哨兵串不撞 nx 那条边界规则）" \
	hint_not_warned '通配规则'
check "随包发布的默认表：判定照常" [ "$(list_tag my-nx-box)" = 主机名特征 ]
export UU_HINT_FILE="$HINTS"
# 清空表是"关掉主机名判定"的正当用法，HINT_RE 为空。探针若不先查 -n，空正则
# 会让两串哨兵双双命中，在没有任何规则的表上骂一句"有通配规则"
: >"$HINTS"
check "清空表不被诬告成通配规则" hint_not_warned '通配规则'
# 同理，前一道闸已经停用了，不许再补一句自相矛盾的警告
printf 'switch(\n' >"$HINTS"
check "非法正则被停用后不再叠一句通配警告" hint_not_warned '通配规则'
# 哨兵串本身的形状是这道闸的前提，静态钉一遍：一串纯字母、一串纯数字。
# 两串都是字母（或都是数字）时，[a-z]/[0-9] 的放行就没了依据
PROBE_A=$(sed -n "s/^HINT_PROBE_ALPHA='\(.*\)'\$/\1/p" "${FILES_DIR}/uuplugin-scan")
PROBE_D=$(sed -n "s/^HINT_PROBE_DIGIT='\(.*\)'\$/\1/p" "${FILES_DIR}/uuplugin-scan")
check "字母哨兵是纯字母" sh -c 'echo "$1" | grep -qxE "[a-z]+"' _ "$PROBE_A"
check "数字哨兵是纯数字" sh -c 'echo "$1" | grep -qxE "[0-9]+"' _ "$PROBE_D"
# 同 20c：警告在父进程里印一次，不按局域网设备台数刷屏
printf '.*\n' >"$HINTS"
: >"$UU_LEASES"
for i in 1 2 3 4 5; do
	printf '1734567899 02:00:00:aa:bb:0%s 10.0.0.%s host%s *\n' "$i" "$i" "$i" \
		>>"$UU_LEASES"
done
# || true 不能省：一条都没匹配上时 grep -c 打印 0 但退出 1，而本文件开了
# set -e，赋值语句的退出码就是命令替换的退出码——整套测试会在这里直接断掉，
# 连末尾的"结果：N 通过，M 失败"都印不出来。要的是一条干净的 FAIL，不是哑火
warn_lines=$("${SANDBOX}/uu-scan" list 2>&1 >/dev/null | grep -c '通配规则' || true)
check "5 台设备只警告一次（通配闸）" [ "$warn_lines" = "1" ]
rm -f "$HINTS"
: >"$UU_LEASES"

# ---------------------------------------------------------------------------
# lan_iface / wan_iface：接口逻辑名可配（默认 lan/wan）
# ---------------------------------------------------------------------------

# service_triggers 的记录桩：把 procd_add_interface_trigger 收到的参数个数
# 与第 2 参记下来。防的是参数左移——漏引号且值为空时 $# 变 3、$2 变
# /etc/init.d/uuplugin，这两个数字是左移唯一藏不住的地方。init 的 shebang
# `#!/bin/sh /etc/rc.common` 在 source 时只是注释（同 18f 那批场景的驱动，
# 这里另起一个是因为还要 stub 两个 procd_add_*_trigger）。
TRIGGER_OUT="${SANDBOX}/trigger-out"
cat >"${SANDBOX}/trigger-driver" <<EOF
#!/bin/sh
USE_PROCD=1
extra_command() { :; }
procd_add_reload_trigger() { :; }
procd_add_interface_trigger() { printf '%s %s\n' "\$#" "\${2:-}" >>'${TRIGGER_OUT}'; }
. '${SANDBOX}/uuplugin.init'
service_triggers
EOF
chmod +x "${SANDBOX}/trigger-driver"
run_triggers() { # run_triggers [VAR=VAL ...]
	: >"$TRIGGER_OUT"
	env "$@" "${SANDBOX}/trigger-driver" >/dev/null 2>&1
}
trigger_rec() { cat "$TRIGGER_OUT"; }

scenario "24a. lan_iface/wan_iface 都未设：行为与现状逐字节相同"
uci -q delete uuplugin.main.lan_iface || true
uci -q delete uuplugin.main.wan_iface || true
: >"$IP_LOG"
env -u UU_LAN_DEV "${SANDBOX}/uu-scan" list >/dev/null 2>&1
check "scan 的兜底设备名仍是 br-lan" grep -q "dev br-lan" "$IP_LOG"
NET_LOG_B="${SANDBOX}/net-log-b"
: >"$NET_LOG_B"
: >"$PING_LOG"
env -u UU_LAN_SUBNET -u UU_LAN_DEV PING_LOG="$PING_LOG" NET_LOG="$NET_LOG_B" \
	FAKE_LAN_SUBNET=172.31.9.5/28 "${SANDBOX}/uu-scan" sweep >"$SWEEP_OUT" 2>&1
check "sweep 问 netifd 要的仍是 lan 的子网" \
	grep -qx "network_get_subnet lan" "$NET_LOG_B"
check "resolve 问的仍是 lan 的设备" \
	grep -qx "network_get_device lan" "$NET_LOG_B"
run_sweep ''
check "文案仍逐字是'取不到 lan 子网'" grep -qF '取不到 lan 子网' "$SWEEP_OUT"
run_triggers
check "trigger 仍是 4 参、接口位 wan" [ "$(trigger_rec)" = "4 wan" ]

scenario "24b. lan_iface=home：resolve 走 home、兜底 br-home、文案含 home"
uci set uuplugin.main.lan_iface=home
: >"$IP_LOG"
env -u UU_LAN_DEV "${SANDBOX}/uu-scan" list >/dev/null 2>&1
check "邻居表查询兜底到 br-home" grep -q "dev br-home" "$IP_LOG"
: >"$NET_LOG_B"
env -u UU_LAN_SUBNET -u UU_LAN_DEV PING_LOG="$PING_LOG" NET_LOG="$NET_LOG_B" \
	FAKE_LAN_SUBNET=172.31.9.5/28 "${SANDBOX}/uu-scan" sweep >/dev/null 2>&1
check "问 netifd 要的是 home 的子网" \
	grep -qx "network_get_subnet home" "$NET_LOG_B"
check "问 netifd 要的是 home 的设备" \
	grep -qx "network_get_device home" "$NET_LOG_B"
run_sweep ''
check "文案报实际接口名：取不到 home 子网" grep -qF '取不到 home 子网' "$SWEEP_OUT"
# 环境变量覆盖优先于 uci
: >"$NET_LOG_B"
env -u UU_LAN_SUBNET -u UU_LAN_DEV NET_LOG="$NET_LOG_B" UU_LAN_IFACE=ovr \
	FAKE_LAN_SUBNET=172.31.9.5/28 PING_LOG="$PING_LOG" \
	"${SANDBOX}/uu-scan" sweep >/dev/null 2>&1
check "UU_LAN_IFACE 覆盖 uci 值" grep -qx "network_get_subnet ovr" "$NET_LOG_B"

scenario "24c. lan_iface 非法（br-lan，含 -）：回落 lan 并 warn"
uci set uuplugin.main.lan_iface=br-lan
: >"$IP_LOG"
: >"$LOGGER_LOG"
env -u UU_LAN_DEV "${SANDBOX}/uu-scan" list >/dev/null 2>&1
check "回落默认：邻居表仍查 br-lan" grep -q "dev br-lan" "$IP_LOG"
check "留下 warn 日志" grep -q '含非法字符' "$LOGGER_LOG"
check "warn 里带上原值方便定位" grep -q 'br-lan' "$LOGGER_LOG"
: >"$NET_LOG_B"
env -u UU_LAN_SUBNET -u UU_LAN_DEV NET_LOG="$NET_LOG_B" PING_LOG="$PING_LOG" \
	FAKE_LAN_SUBNET=10.0.0.1/28 "${SANDBOX}/uu-scan" sweep >/dev/null 2>&1
check "sweep 问的也回落到 lan" grep -qx "network_get_subnet lan" "$NET_LOG_B"

scenario "24d. lan_iface 为空串：回落默认且不 warn（空=没设，不是写坏了）"
uci set 'uuplugin.main.lan_iface='
: >"$IP_LOG"
: >"$LOGGER_LOG"
env -u UU_LAN_DEV "${SANDBOX}/uu-scan" list >/dev/null 2>&1
check "回落默认：邻居表查 br-lan" grep -q "dev br-lan" "$IP_LOG"
check "不告警" sh -c "! grep -q '含非法字符' '$LOGGER_LOG'"
uci -q delete uuplugin.main.lan_iface || true

scenario "24e. wan_iface=wan6x：trigger 的接口参数就是 wan6x"
uci set uuplugin.main.wan_iface=wan6x
run_triggers
check "接口位 = wan6x，仍是 4 参" [ "$(trigger_rec)" = "4 wan6x" ]
run_triggers UU_WAN_IFACE=pppoe_wan
check "UU_WAN_IFACE 覆盖 uci 值" [ "$(trigger_rec)" = "4 pppoe_wan" ]
uci -q delete uuplugin.main.wan_iface || true

scenario "24f. defaults 按 lan_iface 找 zone：network 列表与反向声明两条路"
# 清场：把此前场景留下的 zone / 转发 / network.lan 全摘掉，防串味
uci -q delete firewall.uu || true
uci -q delete firewall.lan_uu || true
uci -q delete firewall.uu_lan || true
for s in $(uci -q _sections firewall zone); do uci delete "firewall.${s}"; done
for s in $(uci -q _sections firewall forwarding); do uci delete "firewall.${s}"; done
uci -q delete network.lan || true
uci set uuplugin.main.lan_iface=home
# 路 1：zone 的 network 列表含 home（home 不排第一，防"挑第一个"蒙对）
uci set firewall.zh=zone
uci set firewall.zh.name=hz
uci add_list firewall.zh.network=guest
uci add_list firewall.zh.network=home
run_defaults
check "退出码 0" [ "$rc" = 0 ]
check "lan->uu 的源指向纳管 home 的 zone" uci_is firewall.lan_uu.src hz
check "uu->lan 的目标同 zone" uci_is firewall.uu_lan.dest hz
# 路 2：network.home.zone 反向指回
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci delete firewall.zh
uci set firewall.zt=zone
uci set firewall.zt.name=tz
uci set network.home=interface
uci set network.home.zone=tz
run_defaults
check "认出 network.home.zone 指向的 zone" uci_is firewall.lan_uu.src tz
# 找不到时的报错点名实际接口
uci delete firewall.uu
uci delete firewall.lan_uu
uci delete firewall.uu_lan
uci delete firewall.zt
uci delete network.home
: >"$LOGGER_LOG"
run_defaults
check "找不到 zone：报错退出" [ "$rc" = 1 ]
check "报错文案点名实际接口 home" grep -q '纳管 home' "$LOGGER_LOG"
uci -q delete uuplugin.main.lan_iface || true
rm -f "$UNPROVEN" # 上面成功那两趟会留标记，别影响后续场景

scenario "24g. service_triggers 防左移：未设/设空/设非法一律 4 参、接口位 wan"
uci -q delete uuplugin.main.wan_iface || true
run_triggers
check '未设：$#=4 且 $2=wan' [ "$(trigger_rec)" = "4 wan" ]
uci set 'uuplugin.main.wan_iface='
: >"$LOGGER_LOG"
run_triggers
check '设空：$#=4 且 $2=wan（引号防左移、校验防空接口）' \
	[ "$(trigger_rec)" = "4 wan" ]
check "设空不告警（空=没设）" sh -c "! grep -q '含非法字符' '$LOGGER_LOG'"
uci set 'uuplugin.main.wan_iface=br-wan'
: >"$LOGGER_LOG"
run_triggers
check '设非法：$#=4 且 $2=wan' [ "$(trigger_rec)" = "4 wan" ]
check "设非法留 warn" grep -q '含非法字符' "$LOGGER_LOG"
uci -q delete uuplugin.main.wan_iface || true

scenario "24h. 静态钉子：接口名校验字符集三处逐字一致"
# 校验在 scan / init / defaults 各写了一份（刻意不建共享库）。谁漂一个
# 字，那个文件就静默接受/拒绝不一样的接口名——运行期测试只喂了合法值和
# 一两种非法值，对漂移一无所知，只能静态抠出来比对（模式同场景 0 的
# 状态目录默认值钉）。抠法：接口名校验的 case 主语都叫 *_IFACE（这也是
# 命名约定的一部分），取该 case 块里的否定字符集。
iface_charset() { # $1=文件 -> 接口名校验 case 里的否定字符集
	sed -n '/case .*_IFACE/,/esac/p' "$1" | grep -o '\[![^]]*\]' | head -1
}
CS_SCAN=$(iface_charset "${FILES_DIR}/uuplugin-scan")
CS_INIT=$(iface_charset "${FILES_DIR}/uuplugin.init")
CS_DFLT=$(iface_charset "${FILES_DIR}/uuplugin.defaults")
check "三处都抠得出来且逐字一致" sh -c \
	'[ -n "$1" ] && [ "$1" = "$2" ] && [ "$2" = "$3" ]' \
	_ "$CS_SCAN" "$CS_INIT" "$CS_DFLT"
check "字符集正是 uci_validate_name 的那套（[A-Za-z0-9_]）" \
	sh -c '[ "$1" = "[!A-Za-z0-9_]" ]' _ "$CS_SCAN"

# ---------------------------------------------------------------------------
# uu-fetch 的 API 主机
# ---------------------------------------------------------------------------

scenario "21. uu-fetch：API 主机可被覆盖（内网镜像 / 离线测试）"
printf "DISTRIB_ARCH='x86_64'\n" >"${SANDBOX}/openwrt_release"
sed -e "s|/etc/openwrt_release|${SANDBOX}/openwrt_release|" \
	"${BIN_FILES_DIR}/uu-fetch" >"${SANDBOX}/uu-fetch"
chmod +x "${SANDBOX}/uu-fetch"
UCF_LOG="${SANDBOX}/ucf-log"
: >"$UCF_LOG"
rc=0
env UCF_LOG="$UCF_LOG" \
	UCF_BODY='url=https://cdn.example/v14.2.2/uu.tar.gz
md5=deadbeef
' UU_API_HOST=mirror.example.invalid UU_DIR="${SANDBOX}/uu" \
	"${SANDBOX}/uu-fetch" --check >"${SANDBOX}/fetch-out" 2>&1 || rc=$?
check "API 请求打到了覆盖的主机" \
	grep -q '^https://mirror\.example\.invalid/api/plugin' "$UCF_LOG"
check "没有打到写死的官方主机" sh -c "! grep -q 'router\.uu\.163\.com' '$UCF_LOG'"
check "架构参数照常带上" grep -q 'type=openwrt-x86_64' "$UCF_LOG"
check "--check 未安装时报版本不一致" [ "$rc" = "1" ]
check "远端版本解析正常" grep -q '远端：14.2.2' "${SANDBOX}/fetch-out"
: >"$UCF_LOG"
env UCF_LOG="$UCF_LOG" UCF_RC=1 UU_DIR="${SANDBOX}/uu" \
	"${SANDBOX}/uu-fetch" --check >/dev/null 2>&1 || true
check "不覆盖时仍走官方主机（默认值没被改坏）" \
	grep -q 'router\.uu\.163\.com' "$UCF_LOG"
check "https 不通会退回 http（同一主机）" \
	sh -c "grep -q '^http://router\.uu\.163\.com/api/plugin' '$UCF_LOG'"

# ---------------------------------------------------------------------------
# 自述帮助
# ---------------------------------------------------------------------------

scenario "22. usage：按注释块的实际长度打印，不写死行号"
usage_of() { # $1=脚本路径 -> 帮助文本（脚本会以 1 退出，那是它该做的）
	sh "$1" no-such-command 2>&1 || true
}
U=$(usage_of "${SANDBOX}/uu-scan")
check "scan：打到第一行非注释为止，不带脚本正文" \
	sh -c "! printf '%s' \"\$1\" | grep -q '^\\. /lib'" _ "$U"
check "scan：首行的 #!/bin/sh 不进帮助" \
	sh -c "! printf '%s' \"\$1\" | grep -q 'bin/sh'" _ "$U"
check "scan：注释里的 # 前缀被剥掉" \
	sh -c "! printf '%s' \"\$1\" | grep -q '^#'" _ "$U"
check "scan：头部最后一行也在（不是被写死的行号截断的）" \
	sh -c "printf '%s' \"\$1\" | grep -q 'service uuplugin add'" _ "$U"
check "scan：新加的环境变量段落自动进了帮助" \
	sh -c "printf '%s' \"\$1\" | grep -q 'UU_SWEEP_MAX'" _ "$U"
U=$(usage_of "${FILES_DIR}/uuplugin-guard")
check "guard：头部最后一行也在" \
	sh -c "printf '%s' \"\$1\" | grep -q 'health_url'" _ "$U"
check "guard：不带脚本正文" \
	sh -c "! printf '%s' \"\$1\" | grep -q 'set -u'" _ "$U"

# ---------------------------------------------------------------------------

printf '\n结果：%d 通过，%d 失败\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
