# Internet Detector CPE Recovery Component

The user specified the workflow and clarified that it must be built and installed
as a component of this repository, like existing SDK package jobs. Execute inline
using TDD and verification-before-completion; request code review.

## Design and constraints

Build upstream `internet-detector` and `luci-app-internet-detector` at pinned
commit `a4ac581a57121de0c6e8628028eaaea36a524576` with each target's SDK. Pass the
packages to ImageBuilder, which installs them through its package manager and
resolves dependencies. Package settings and recovery scripts as `cpe-watchdog`.
No replacement daemon or custom LuCI app.

Use only HTTPS URL tests, every 300 seconds online and offline. Any target
returning an HTTP response through verified TLS means online; bound transfers
and never follow HTTP redirects. Harden upstream curl invocation with a patch.
Disable built-in reboot/network/modem actions. Enable only down-script, with
unlimited attempts and 300-second retry intervals, including startup outages.

Recovery locks against overlapping calls, allows 300 seconds of boot time before
acting, and rechecks the same HTTPS list. If offline, detect the CPE via its basic
information API. Support verified Huawei H155-380 via challenge/authentication
and device/control APIs. Wait 120 seconds after the attempt; recheck HTTPS and
reboot OpenWrt only if all fail. CPE errors cannot suppress fallback. No persisted
once-only flag; every boot and outage can repeat the flow.

Provision passwords only on-device in `/etc/cpe-watchdog/password`, mode 0600;
never in the repository or build artifacts. Firmware defaults to disabled until
provisioned. Preserve configuration/credentials on sysupgrade. Follow-up authorization allows installation and enablement on the live router.
Use nondestructive verification; the user will perform the real outage test.

## Tasks

### 1. Recovery scripts

Files: `watchdog/overlay/usr/lib/cpe-watchdog/{recovery,cpe}.py`,
`tests/test_{recovery,cpe}.py`.

- [x] Write/run failing tests for HTTPS OR checks, TLS verification, ordering,
  CPE failure fallback, repeated cycles, model dispatch and API authentication.
- [x] Implement `Settings`, `https_online`, `recover`, UCI parsing, credentials
  and `HuaweiCpe`. Mock only hardware/network/time boundaries.
- [x] Verify against controlled real TLS and CPE HTTP servers.

### 2. Package and configuration integration

Files: `watchdog/build_packages.sh`, `watchdog/source.env`, patches,
`watchdog/overlay/etc/...`, the unified image workflow, README.

- [x] Add pinned-source SDK jobs/artifacts to the unified workflow.
- [x] Install the glue package by name and declare curl/ca-bundle/Python dependencies.
- [x] Add UCI defaults, callback, sysupgrade keep list, provisioning instructions.
- [x] Verify shell/YAML, patch application, package compilation with cached SDKs
  and actual package payload/configuration delivery.

### 3. Review and verification

- [x] Independent review; resolve important findings.
- [x] Run complete tests and package/build integration checks.
- [x] Use real device only for nondestructive HTTPS/model checks; no reboot POST.
- [x] Document evidence and runtime credential/enable instructions.

## Verification notes

26 unit/integration tests pass, including actual local TLS and CPE HTTP fixture
servers, repeat outages, authentication proof/token handling and first-boot
configuration preservation. The Lua/LuCI check runs the actual pinned upstream
modules and validates interim HTTP responses, literal URL quoting, HTTPS-only
validation and unlimited callbacks. Live nondestructive probes identified
H155-380 and confirmed HTTPS connectivity; no reboot API was sent.

SDK exercise found and fixed feed-name parsing, root/buildbot ownership and stale
staging on retries. Disable SDK ALL defaults. Assemble the script-only glue package
with NO_DEPS, retaining runtime dependencies in its manifest for ImageBuilder to
resolve; the other packages compile normally. This avoids compiling runtime
libraries whose source mirrors may fail despite available firmware packages.

Both x86 SDK jobs (24.10.0 and 25.12.0) exited successfully and produced all
three packages in IPK and APK format respectively. Payload inspection confirms
current scripts, HTTPS patch, dependency declarations and absence of passwords,
bytecode and overlapping configuration ownership. Full firmware images and
other architectures have not been built locally; live recovery was subsequently installed and enabled at the user's request.

The remote master migrated to Debian 13 SDK tarball preparation and removed the
retired mt7981 workflow. Integration retains those changes and adds a watchdog
test gate plus package job for the current unified target matrix.

Live 25.12.5 verification passed HTTPS, H155-380 identity and SCRAM login;
procd reports running and startup symlinks exist. Two detector rounds were
observed approximately 300 seconds apart. Persistent records exclude the actual
credential value. Audit logs correlate each recovery with the last completed
detector decision and fsync before any reboot request.
