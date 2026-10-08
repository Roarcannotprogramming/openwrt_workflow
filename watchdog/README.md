# HTTPS CPE watchdog component

The unified firmware workflow builds three packages: `internet-detector`,
`luci-app-internet-detector`, and `cpe-watchdog`. ImageBuilder installs them with
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
Attempts = 0 means unlimited; On startup must stay enabled. Each factory-flashed
device needs its own runtime password provisioning and explicit enablement.

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
The x86 SDKs for 24.10.0 and 25.12.0 produced the three IPK/APK packages; extracted
payloads match current sources and contain no credential files. Full firmware
builds, other architectures and real reboot execution remain untested locally.

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
