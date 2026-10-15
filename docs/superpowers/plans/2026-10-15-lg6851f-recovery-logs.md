# LG6851F recovery and complete LuCI history

> Execute the approved work in this session; keep runtime credentials only on each router.

**Goal:** Support Huawei H155-380 and FiberHome LG6851F through the same recovery settings and display all retained audit history in LuCI on both routers.

**Architecture:** Preserve the existing HTTPS detector and recovery ordering. Add a model-specific FiberHome client with the device's AES-CBC/session protocol. Add a narrow authenticated read-only RPC and LuCI page for paginated history and JSONL export including rotation archives. Provision identical configuration schemas on both devices, differing only in endpoint and their private credentials.

**Constraints:** No real usernames/passwords/cookies/tokens or captured live API payloads in Git. No deliberate outage or reboot during verification. Keep existing Huawei operation compatible. Preserve retained logs and make rollback backups on the routers.

## Task 1 — FiberHome protocol and model dispatch
- [x] Extract the protocol from the device's own JavaScript into private temporary research files outside Git.
- [x] Add failing HTTP fixture tests for encrypted requests, authentication, model dispatch, API failure, and refusal to reboot without authenticated supported identity.
- [x] Implement `fiberhome.py`, extend `cpe.py` dispatch and remove the Huawei-only authentication branch in `recovery.py`.
- [x] Add package dependency for AES implementation and sanitized timing/error audit fields.
- [x] Run fixture tests, then execute detect/authenticate against the real CPE without invoking reboot.

## Task 2 — Complete LuCI history
- [x] Add failing tests for current plus rotated history, pagination, filtering, malformed records, bounded input and omission of unexpected sensitive fields.
- [x] Implement read-only `luci.cpe-watchdog` RPC using fixed history paths and narrow ACL permissions.
- [x] Implement Chinese LuCI page with refresh, date/event filtering, paging, raw details and complete JSONL export.
- [x] Install menu/assets/RPC/ACL in the package and verify JavaScript syntax and RPC behavior.

## Task 3 — Symmetric provisioning and deployment
- [x] Back up existing files locally on each router; keep backups private and outside Git.
- [x] Provision the same new UCI schema and credential-file layout on both routers; migrate the old credential on the FiberHome router without printing or exporting it.
- [x] Remove the obsolete cron invocation on the FiberHome router and preserve unrelated cron entries.
- [x] Deploy matching code/UI on both routers, run nondestructive check/detect/authenticate, then enable background monitoring.
- [x] Check live automatic rounds, authenticate the LuCI RPC/UI, scan changed Git files for actual credential values without printing matches, and request independent code review.
- [x] Report actual configuration files and the two routers' config contents without credential-file contents.

## Validation

Run `python3 -m unittest discover -s tests -v` on Linux with audit output redirected by the test harness to a temporary directory; the existing audit tests depend on Linux `/proc`. Run Node UI/RPC contract tests and shell syntax checks. No test may invoke a real reboot. Before deploying to both devices, preserve local backups and verify the model-specific authentication checks. Re-run relevant tests after review fixes.
