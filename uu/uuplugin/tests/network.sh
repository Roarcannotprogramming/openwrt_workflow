# 测试用的假 /lib/functions/network.sh —— 只实现 uuplugin-scan 用到的两个。
#
# 真机上它们经 ubus 问 netifd；这里由环境变量喂值，不喂就返回 1（等价于
# "问不到"）。这样"脚本到底有没有去问系统要网段"才成为可断言的事实：
# 所有 sweep 用例都显式设了 UU_LAN_SUBNET，把 resolve_subnet 的调用整个
# 删掉它们照样全绿——得有一条不喂值的用例，才能真正绊住那种改动。
#
# 设了 NET_LOG 就把每次调用连同被问的接口名记下来，供断言"问的是 lan"。

network_get_device() { # $1=输出变量名 $2=接口名
	[ -n "${NET_LOG:-}" ] && echo "network_get_device $2" >>"$NET_LOG"
	[ -n "${FAKE_LAN_DEV:-}" ] || return 1
	eval "$1=\$FAKE_LAN_DEV"
}

network_get_subnet() { # $1=输出变量名 $2=接口名
	[ -n "${NET_LOG:-}" ] && echo "network_get_subnet $2" >>"$NET_LOG"
	[ -n "${FAKE_LAN_SUBNET:-}" ] || return 1
	eval "$1=\$FAKE_LAN_SUBNET"
}
