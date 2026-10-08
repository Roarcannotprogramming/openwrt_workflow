# HTTPS CPE watchdog component

The unified firmware workflow builds four packages: `internet-detector`,
`luci-app-internet-detector`, `luci-i18n-internet-detector-zh-cn`, and `cpe-watchdog`. ImageBuilder installs them with
its package manager and resolves curl, CA certificates, Python and Lua dependencies.
The script-only recovery package is assembled without compiling its runtime
dependencies in the SDK; these are installed from the target firmware repositories.
[Upstream Internet Detector](https://github.com/gSpotx2f/luci-app-internet-detector)
is pinned by commit and archive SHA-256 in `source.env`. Watchcat uses ping,
so Internet Detector provides the required URL checks and LuCI script settings.

## Recovery behavior

Internet Detector uses **URL test**, with a five-minute interval both online and
offline. Default HTTPS URLs are Baidu, QQ and Bing; any reachable URL means online.
All probes verify TLS certificates and have a total request timeout. An HTTP
response, including a 4xx/5xx response, proves HTTPS connectivity; redirects are
not followed. No ping, TCP-only, modem status or single-host vote determines health.

On failure the down-script rechecks the same HTTPS list, identifies the CPE, and
dispatches its model-specific API. The verified handler supports **Huawei H155-380
(5G CPE 5)** using challenge/response login and `POST /api/device/control` with
`Control=1`. Unknown models are logged without guessed reboot commands. All CPE
attempts, including failures, are followed by a 120-second wait and HTTPS recheck.
OpenWrt reboots only if every target still fails.

Down-script retries are unlimited, callbacks cannot overlap, and procd resumes
the detector after boot. A 300-second boot grace period allows network startup.
No permanent "already rebooted" flag exists. Configuration and credentials are
preserved by sysupgrade. Recovery scripts read the current URL list each time.

## Provision credentials after flashing

The firmware enables the service at boot but ships with detector mode **Disabled**.
It contains no password. On the router create a private credential file:

```sh
mkdir -p /etc/cpe-watchdog
chmod 700 /etc/cpe-watchdog
python3 - <<'PYCODE'
import getpass
import os
fd = os.open('/etc/cpe-watchdog/password', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
try:
    os.write(fd, getpass.getpass('CPE password: ').encode())
finally:
    os.close(fd)
PYCODE
```

The prompt hides the password while typing. Do not put it in the command line,
UCI, a shell history entry, the repository, or an Actions secret used to
produce downloadable firmware. The file must be owned by root and mode 0600.

Run nondestructive checks before enabling recovery:

```sh
python3 /usr/lib/cpe-watchdog/recovery.py check
python3 /usr/lib/cpe-watchdog/recovery.py detect
python3 /usr/lib/cpe-watchdog/recovery.py authenticate
uci set internet-detector.config.mode='1'
uci commit internet-detector
/etc/init.d/internet-detector enable
/etc/init.d/internet-detector restart
```

In **LuCI → Services → Internet Detector**, keep the instance on URL test and edit
the URL list or intervals. Leave built-in device/network/modem reboot modules
disabled; the User scripts down-script controls the ordered recovery instead.
Offline-script attempts = 0 means unlimited; **Run offline script when initially
offline** must stay enabled. The corresponding online-script startup action
stays disabled. Each factory-flashed
device needs its own runtime password provisioning and explicit enablement.

## 中文页面与推荐设置

组件会安装简体中文语言包，翻译所有标签页、子标签页、字段、状态、错误提示和说明。
LuCI 的语言选择“简体中文”，或使用“自动”并让浏览器首选语言为中文。
页面每个标签页都会说明作用和推荐状态。以下设置针对预置的 `internet` 实例。

| 页面或选项 | 本方案的设置 | 含义 |
| --- | --- | --- |
| 监测运行方式 | 后台服务（持续运行） | 关闭网页后仍持续监测和恢复 |
| OpenWrt 开机自动启动服务 | 已启用 | 每次 OpenWrt 重启后自动运行监测服务；按钮立即切换状态 |
| 主要设置 → 启用此监测实例 | 开启 | 开启 `internet` 实例的检查，不会自动开启其他模块 |
| 主要设置 → 检查方式 | 网址访问（验证 HTTPS） | 只使用 HTTPS 连通性；任意一个目标返回响应即可 |
| 主要设置 → 联网/断网时检查间隔 | 均为 5 分钟 | 两轮常规检查的间隔 |
| 主要设置 → 每个目标的检查次数 / 单次连接超时 | 1 次 / 15 秒 | 不表示重启次数；代理保持关闭 |
| 用户脚本（CPE 恢复） → 启用联网及断网脚本 | 开启 | 用预置断网脚本控制“先 CPE，后 OpenWrt” |
| 用户脚本 → 断网脚本 → 首次已断网时执行断网脚本 | 开启 | 服务刚启动时已断网，也执行恢复；配合开机自启保证重启后继续恢复 |
| 用户脚本 → 断网脚本 → 等待时间 / 执行次数上限 / 重试间隔 | 0 秒 / 不限次数 / 5 分钟 | 检测到断网后立即执行；持续断网会继续重试，恢复流程不会重叠 |
| 用户脚本 → 联网脚本 → 首次已联网时执行联网脚本 | 关闭，脚本留空 | 本方案无需联网时执行额外命令 |
| 重启 OpenWrt | 关闭 | 内置模块会直接重启本机，跳过 CPE 优先恢复 |
| 重启 OpenWrt 网络 / 重启本地调制解调器 | 关闭 | 不负责外部 CPE 的 API 重启 |
| 定时脚本 | 关闭 | 这是额外的定时脚本，不是常规 HTTPS 检查 |
| LED 指示灯 / 公网 IP 查询 / 邮件或 Telegram 通知 | 默认关闭，按需启用 | 只提供显示或通知，不参与连通性判定和恢复 |

“开机自动启动服务”控制服务是否随系统启动；各模块的“服务启动时触发”
控制首次检测就处于相应状态时是否执行动作，二者不能互相替代。
恢复脚本默认在 OpenWrt 开机后的前 5 分钟保留网络启动宽限时间。
新刷固件没有密码，监测运行方式默认关闭；必须先按上文配置设备上的私有密码文件并验证，
再切到后台服务。已配置的设备升级时保留现有密码和配置。

`/etc/config/cpe-watchdog` controls the CPE address, username, credential path,
120-second wait and local reboot executable/script. `reboot_command` accepts an
absolute executable/script plus arguments; it is executed without shell evaluation.
For multiple custom commands, point it at your own executable shell script.

## Verification

```sh
mkdir -p "$HOME/.paseo/.tmp"
TMPDIR="$HOME/.paseo/.tmp" python3 -m unittest discover -s tests -v
bash -n watchdog/build_packages.sh
```

The tests use fixture credentials and simulated reboot boundaries; they do not
reboot real devices. The upstream patch makes URL testing HTTPS-only, gives curl
a total deadline, quotes target URLs safely and applies transport-only HTTP status
semantics consistently with the recovery script.

Local verification: 26 tests and the pinned Lua/LuCI behavior checks passed.
The x86 SDKs for 24.10.0 and 25.12.0 produced the IPK/APK packages; extracted
payloads match current sources and contain no credential files. Full firmware
builds, other architectures and real reboot execution remain untested locally.

Chinese UI verification on OpenWrt 25.12.5: Chromium opened all seven installed
tabs and both script sub-tabs, checking translated labels, explicit enable
controls, background mode and Chinese factory script comments. The tests also
construct optional modem/email/Telegram pages and simulate core catalog overrides.
Both package formats contain the same compiled Chinese catalog. The installed
upgrade preserved the configured recovery script; HTTPS checks and boot
supervision remain active. No real reboot was requested during verification.

## Persistent outage-test history

All detector probes and completed rounds are recorded in
`/etc/cpe-watchdog/events.jsonl`, including successful checks while online.
The detector stops at the first reachable endpoint; each round records how many
remaining endpoints were skipped. Recovery checks probe every configured target.
Only the hostname/authority is recorded, never URL paths, query strings, API
payloads, credentials, tokens or cookies.

Each record includes UTC time, boot ID, monotonic uptime, process ID and cycle ID.
The down-script inherits the last completed detector decision's cycle ID so its
CPE identification, API path/results, reboot attempt, 120-second wait, HTTPS
recheck and OpenWrt reboot request can be correlated precisely. Startup and
shutdown events distinguish boots and service restarts. A reboot request records
the decision, not proof that the hardware finished rebooting; the next startup
record provides that evidence.

Writes are serialized across processes, and both the file and its directory are
fsynced before returning, including before issuing the OpenWrt reboot command.
The active file is limited to 1 MiB and keeps four rotated files (`.1` through
`.4`); all are mode 0600 and remain on persistent overlay across reboot and
sysupgrade. Syslog also receives these events. An audit write failure emits an
error to syslog without blocking recovery. Finite storage cannot retain an
unlimited test history; export the files before rotation discards old records.

Inspect current and previous records on the router:

```sh
tail -n 50 /etc/cpe-watchdog/events.jsonl
logread -e cpe-watchdog
```

Export `events.jsonl` and its existing numbered archives for an outage-test
analysis. No intentional live outage/reboot was performed during deployment.

Live deployment on OpenWrt 25.12.5 (192.168.17.1): three r2 APKs installed,
CPE identity and authentication verified, procd service enabled, and two
successful automatic rounds observed approximately 300 seconds apart. Persistent
history was checked for the actual credential value and contains none.
