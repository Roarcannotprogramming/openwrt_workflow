# 测试用的假 /lib/functions.sh —— 只实现 uuplugin-render 用到的四个函数，
# 数据来源是假 uci（见 fake-uci.py）。

config_load() {
	_CONFIG_NAME="$1"
}

config_foreach() {
	local _cb="$1" _type="$2" _sec
	for _sec in $(uci -q _sections "$_CONFIG_NAME" "$_type"); do
		"$_cb" "$_sec"
	done
}

config_get() {
	local _var="$1" _sec="$2" _opt="$3" _def="${4:-}" _val
	_val=$(uci -q get "${_CONFIG_NAME}.${_sec}.${_opt}") || _val="$_def"
	eval "$_var=\$_val"
}

config_get_bool() {
	local _var="$1" _sec="$2" _opt="$3" _def="${4:-0}" _val
	_val=$(uci -q get "${_CONFIG_NAME}.${_sec}.${_opt}") || _val="$_def"
	case "$_val" in
	1 | on | true | yes | enabled) _val=1 ;;
	*) _val=0 ;;
	esac
	eval "$_var=\$_val"
}
