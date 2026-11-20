# zapret-lazy — conventions and contracts

This file is the single source of truth for module boundaries, state formats,
log markers and scoring rules. Changes here require a DEVLOG entry.

## Language and style

- Identifiers, comments, log markers, DEVLOG entries: English only.
- Log marker prefix: `[ZAP-AUTO]`. Format:
  `[ZAP-AUTO] <Module> <Event> key=value key=value`
- No magic numbers: named constants in `settings.json` or at module top.
- Behavioral changes get an observable point: log marker or report entry.

## State ownership (invariants)

| File | Owner (writer) | Readers |
|---|---|---|
| `settings.json` | `Config.psm1` (Save-Config) | all modules, tray |
| `state/status.json` | `ServiceManager.psm1` (engine) | tray |
| `state/strategy-history.json` | `src/Autopilot.ps1` (engine) | engine |
| `state/commands.json` | `tray/TrayApp.ps1` | engine (ServiceManager) |
| `state/commands.processed.json` | engine | diagnostics only |

Derived state never overwrites the canonical source. Only the engine's
validated `setoption` handler may update the two exposed engine options through
`Save-Config`; tray never touches `winws.exe` or the `zapret` service.

## settings.json (schema version 1)

```json
{
  "schemaVersion": 1,
  "gameFilterMode": "all",
  "ipsetMode": "loaded",
  "testSchedule": "onboot",
  "updateCheck": true,
  "test": { "curlTimeoutSec": 4, "winwsReadyTimeoutMs": 5000, "maxParallel": 16, "strategyRestartDelayMs": 500 },
  "monitor": { "watchdogIntervalSec": 10, "commandPollMs": 1000, "pingTargets": ["1.1.1.1", "8.8.8.8"] },
  "widget": { "x": null, "y": null, "visible": true, "autoHideAfterBoot": true, "autoHideDelaySec": 300, "pinned": false },
  "security": { "pinSha256": "", "hardenAcls": true }
}
```

- `gameFilterMode`: `disabled | all | tcp | udp` → port substitution
  `disabled: GameFilter=12 / GameFilterTCP=12 / GameFilterUDP=12`,
  `all: 1024-65535 for all three`, `tcp: TCP=1024-65535, UDP=12`,
  `udp: UDP=1024-65535, TCP=12` (mirrors `service.bat:game_switch_status`).
  Default and invalid-value fallback: `all` (TCP + UDP). Invalid values log
  `InvalidEnumClamped`.
- `ipsetMode`: `loaded | none | any`, applied to `zapret-core/lists/ipset-all.txt`
  exactly like `service.bat:ipset_switch` (none = marker `203.0.113.113/32`,
  any = empty file, loaded = restore backup / downloaded list).
- `testSchedule`: `onboot | every3days | weekly | monthly` — cadence of the
  engine's strategy tests only (`onboot` = test at every engine start, the
  default; the others defer retesting to the first start after the chosen
  interval). Payload update cadence is a separate concern and stays per-boot.
  A manual `retest` command always forces a full test regardless of this gate.
  The widget renders the schedule as a dropdown ('On Windows startup' /
  'Every 2-3 days' / 'Weekly' / 'Monthly') bound to the setting; the change is
  persisted manual state: the tray writes it through
  `Save-Config` only, never sends a command (the engine reads the setting at
  each start). A missing or unknown value is tolerated as `onboot`.
- `security.pinSha256`: optional lowercase SHA256 of `zapret-core\bin\winws.exe`.
  When non-empty, UpdateManager refuses a payload whose winws.exe hash differs
  (fail-closed). Empty = pin not enforced; the measured hash is still recorded
  in the log and report for manual comparison with upstream releases.
- `security.hardenAcls`: when true, Preflight tightens ACLs (see "ACL model").
- `widget.autoHideAfterBoot` / `widget.autoHideDelaySec`: boot-time widget
  behavior. The tray always shows the widget at startup (regardless of
  `widget.visible`) so the user can watch the check progress; when the engine
  reaches phase `monitoring` or `error` and `autoHideAfterBoot` is true, the
  widget keeps showing the final message for `autoHideDelaySec` seconds, then
  hides itself. Auto-hide is per-boot only: it never persists
  `widget.visible=false` to `settings.json`, so the next boot shows the widget
  again (a manual Show/Hide via menu, double-click or the close button still
  persists through `Save-Config` as before). A manual toggle during the
  armed/countdown window cancels the auto-hide for the session. Firing is
  logged once per boot as `Tray WidgetAutoHidden`. Absent properties are
  merged from defaults by `Get-Config` without discarding existing
  `widget.x/y/visible`. Default delay is 300 seconds (5 minutes); setup migrates
  the previous default of 8 seconds on upgrade.
- `widget.pinned`: persisted Pin/Unpin state. A pinned widget skips auto-hide,
  ignores header drag and shows an orange pin marker. Unpin rearms auto-hide.
  The widget uses `WS_EX_TOOLWINDOW` and is excluded from Alt+Tab.

## state/status.json (engine → tray)

```json
{
  "updatedAt": "2026-11-17T22:50:00Z",
  "phase": "boot|update|preflight|testing|installing|monitoring|paused|error",
  "progress": { "stage": "testing", "strategy": "general (ALT2).bat", "index": 3, "total": 10 },
  "activeStrategy": "general (ALT2).bat",
  "serviceState": "running|none|paused",
  "payloadVersion": "1.10.2",
  "gameFilterMode": "all",
  "ipsetMode": "loaded",
  "network": { "up": true, "samples": [ { "target": "1.1.1.1", "ms": 12 }, { "target": "8.8.8.8", "ms": 41 } ] },
  "greenStrategies": ["general.bat", "general (ALT2).bat"],
  "allResults": [ { "strategy": "general.bat", "ok": 42, "err": 0, "unsup": 0, "avgPingMs": 34.2, "fullyGreen": true } ],
  "lastTestAt": "2026-11-17T22:49:00Z",
  "message": "Active: general (ALT2).bat — 42 checks OK",
  "vpn": { "active": false, "name": null }
}
```

- `phase`: `boot|update|preflight|testing|installing|monitoring|paused|error`.
- `vpn` / `paused` (VPN pause): the engine asks the routing table for the best
  IPv4 interface towards `1.1.1.1` (`GetBestInterface`) and classifies it once
  per interface index: IANA ifType 23/53/131 or a known VPN name/driver
  (Wintun, WireGuard, TAP, OpenVPN, xray, Happ, ...) = VPN. While a VPN carries
  the internet route the engine stops its managed winws, writes
  `phase: paused`, `serviceState: paused`, `vpn: { active: true, name }`,
  message `VPN active - zlazy paused`, and polls the route every second
  (status heartbeat every 10 s). Checked before every test run, after the
  baseline, before every strategy under test (`Invoke-StrategyTests
  -ShouldAbort`: a VPN coming up mid-run aborts it, `Engine TestsAborted`,
  `Autopilot TestAborted reason=vpn`, then pause and a fresh test gate) and on
  every monitor poll tick. While paused before any test, the remembered
  strategy is shown in `activeStrategy` for display only and cleared on resume. Only `shutdown` is honoured while paused; other commands
  are dropped (`Autopilot CommandDropped reason=vpnPaused`). When the VPN goes
  away for 5 s in a row (debounce: a reconnecting client briefly hands the
  route back, `Autopilot VpnFlap`) the previous active strategy is restarted (options path), or the test
  gate runs when none was active. A probe failure reads as "no VPN". The tray
  shows the pause bars and `vpn: on · lazy paused`. Markers: `Autopilot
  VpnPaused adapter=…`, `Autopilot VpnResumed`, `Service MonitorExit reason=vpn`.
- `serviceState`: legacy field name; `running` means the engine owns a live
  `zapret-core\bin\winws.exe`, `none` means no managed process. It does not
  describe a Windows service.
- `progress`: boot-time progress for the tray status line. `stage` mirrors
  `phase` with `done` for monitoring and an explicit `error`;
  `strategy`/`index`/`total` identify the strategy under test (`index` is
  1-based). Refreshed per strategy during the testing phase (one atomic
  Write-Status per strategy start); on every other transition `strategy` is
  `null` and `index`/`total` are `0`. Initial value:
  `{ "stage": "boot", "strategy": null, "index": 0, "total": 0 }`. Readers
  must tolerate a missing `progress` (older engine builds). The tray renders
  it as the second widget line: `Testing <index>/<total> — <strategy>` during
  testing, short labels per stage (`Booting...`, `Running preflight...`,
  `Checking for updates...`, `Installing service...`, final `message` for
  `done`/`error`), and the plain `message` line when `progress` is absent.
- `gameFilterMode` / `ipsetMode`: current engine options, published for the
  widget steppers. Readers tolerate their absence (older engines).
- `greenStrategies`: names only, in score order (best first). Empty array when
  nothing passed fully green.
- Written atomically: temp file + move, so tray never reads a partial file.

## Strategy memory and test schedule (engine)

`settings.testSchedule` (`onboot | every3days | weekly | monthly`) governs the
strategy **test** phase only; payload updates stay every-boot regardless. The
engine reads the schedule at every engine start from `Get-Config`. The chosen
strategy survives reboots through the engine-owned `state/strategy-history.json`
(written atomically):

```json
{ "lastStrategy": "general (ALT2).bat", "lastGreen": ["general (ALT2).bat", "general.bat"], "testedAt": "2026-11-17T22:49:00Z" }
```

- **Gate**: `onboot` (default) always tests. Otherwise the engine tests when
  `testedAt` is missing/unparseable or older than the window — 72 h
  (`every3days`), 168 h (`weekly`), 720 h (`monthly`); a missing or
  schema-invalid history file also tests.
- **Skip path** (not due + `lastStrategy` present + its `.bat` still parses
  against the current payload): no `Invoke-StrategyTests`, no `Write-Report`.
  `progress.stage` = `done`, `activeStrategy` = `lastStrategy`,
  `greenStrategies` = `lastGreen`, message
  `Keeping <strategy> (schedule <testSchedule>)`. The StrategyMap is rebuilt by
  re-parsing each green strategy via `Get-WinwsArguments` against the current
  payload (greens whose `.bat` vanished stay in `greenStrategies` but are
  skipped from the map). The managed background winws is then ensured: live
  process → nothing; otherwise start the remembered stock `.bat` through the
  compatibility-named `Install-ZapretService`. No Windows service is created.
  If the remembered `.bat` no longer exists (or parses to zero args), the
  engine falls through to the full test path instead.
- **Test path**: strategies are ordered remembered-first, then the remaining
  `lastGreen` entries in recorded order, then all others (natural sort within
  each group, no duplicates, names not on disk dropped) and passed to
  `Invoke-StrategyTests` — so a remembered strategy shows as `1/<n>` in
  `progress`. **Quick boot**: unless the test was started manually (tray
  retest), the remembered strategy is first tested alone right after the
  baseline; when it is fully green it is installed at once and the other
  strategies are not tested (`Autopilot QuickBootHit`). `greenStrategies` then
  = the remembered strategy + previous `lastGreen` entries still on disk, and
  their arguments are re-parsed into the StrategyMap. Otherwise
  (`QuickBootMiss`) the remaining strategies are tested and merged into one
  ranking via `Get-RankedStrategyResults`. After a successful install the engine writes
  `{ lastStrategy: <chosen>, lastGreen: <greenStrategies>, testedAt: now }`.

- **Manual switch.** A successful tray `switch` also rewrites the history via
  `Set-RememberedStrategy`: `lastStrategy` = the chosen strategy, `lastGreen`
  and `testedAt` unchanged (`Autopilot ManualStrategyRemembered`). The choice
  therefore survives reboots until the next test: the skip path starts it, and
  the quick boot verifies it first and keeps it while it is fully green. Only a
  full test (manual retest, quick boot miss, missing history) replaces it.

## Maintenance while running (engine)

The engine is started once per Windows boot (task `ZapretLazyEngine`, trigger
AtStartup) and then stays in the monitor loop, so everything that used to
happen "at start" also has to happen while it keeps running:

- **Network first.** `Wait-NetworkReady` runs before the update check and
  before every preflight. It repeats `Invoke-NetworkWait` (120 s rounds,
  `Autopilot NetworkStillDown round=N`, message `Waiting for network`) until
  DNS + HTTPS to GitHub work, honours a tray `shutdown`, and never exits the
  engine (previously a 120 s timeout ended the process).
- **Maintenance tick.** `Enter-MonitorLoop -MaintenanceIntervalSec 3600
  -WakeGapSec 1800` returns `@{ Maintenance = $true; Wake = <bool> }` after an
  hour of monitoring, or at once when the wall clock jumped by >= 30 min
  between two poll ticks (resume from sleep/hibernation). Autopilot then logs
  `Autopilot Maintenance wake= updateDue= testDue=` and decides:
  - `updateDue` = wake, or no check yet, or the last check is >= 24 h old
    (and `updateCheck` is not false) -> Update phase. Without a new payload
    and without a due test the engine goes straight back to monitoring with
    the previous message; the running winws is never touched.
  - `testDue` (`Test-ScheduleDue`): `onboot` -> only after a wake (the user
    "turned the PC on"); other schedules -> `testedAt` age >= window. Due ->
    Preflight -> Test gate (quick boot first).
  - nothing due -> back to monitoring silently.

## state/commands.json (tray → engine)

Single command object; tray writes, engine reads, executes, then moves the
file to `state/commands.processed.json` (overwriting). Unknown commands are
logged and dropped.

```json
{ "command": "switch", "strategy": "general (ALT2).bat", "issuedAt": "ISO8601" }
{ "command": "retest", "issuedAt": "ISO8601" }
{ "command": "setoption", "option": "gameFilterMode", "value": "tcp", "issuedAt": "ISO8601" }
{ "command": "shutdown", "issuedAt": "ISO8601" }
```

- `switch`: engine validates the strategy is in the last known
  `greenStrategies` list, then starts its stock `.bat` as the managed process.
- `retest`: engine reruns the full test phase.
- `setoption`: accepts only `gameFilterMode` (`disabled/all/tcp/udp`) or
  `ipsetMode` (`loaded/none/any`) as raw strings. The engine persists through
  `Save-Config`, runs Preflight and reinstalls only the active strategy with
  rebuilt arguments. It does not rerun the strategy test suite.
- `shutdown`: engine exits its monitor loop and the owning finally block stops
  managed winws and removes legacy service/driver entries. A stale shutdown
  found at boot is discarded.
- Validation (ServiceManager): `command` must be a string from the whitelist
  (`switch`, `retest`, `setoption`, `shutdown`); `strategy` must be a string, present in both
  `greenStrategies` and the in-memory StrategyMap. Option names and values use
  independent case-sensitive whitelists. `commands.json` larger than 64 KB is
  rejected (Config `CommandOversize`) and dropped. The tray runs unprivileged,
  so the command channel is treated as untrusted input: it can only choose
  tested strategies, request a retest or set the two exposed options — never
  execute arbitrary code.

## Payload verification (UpdateManager, fail-closed)

After extracting a downloaded release and before swapping it in:

1. `WinDivert64.sys` must have a **Valid** Authenticode signature
   (`Get-AuthenticodeSignature`). Any other status → payload rejected,
   rollback, `Security PayloadRejected` marker.
2. If `security.pinSha256` is set, SHA256 of `winws.exe` must match it
   (case-insensitive). Mismatch → reject + rollback.
3. The measured SHA256 of `winws.exe` is always written to the log
   (`Security PayloadHash sha256=...`) and the report.
4. Extraction must be zip-slip safe: every archive entry's resolved full path
   must stay under the staging root; anything else aborts the update.
5. Staging directories are ACL-tightened (SYSTEM + Administrators only)
   immediately after creation.
6. All payload fetches enforce TLS 1.2+ and use only the pinned GitHub hosts
   (`raw.githubusercontent.com`, `github.com` and its release-asset redirect,
   `release-assets.githubusercontent.com`). No URL from any config/state file
   is ever fetched. The release URL is constructed from the validated numeric
   version, not from GitHub API output.

## Lists lifecycle (normative)

- `zapret-core\lists\` (all files) and `zapret-core\utils\targets.txt` are
  **user data**: they are seeded once — from GitHub at provisioning, or from
  the installer's donor folder (`state\seed-lists.json` overlay, consumed on
  first provision) — and are then carried across payload updates byte-for-byte
  by `Copy-UserData`. Payload updates NEVER refresh them.
- `game_filter.enabled` is derived from `settings.gameFilterMode` at every
  Preflight; `ipset-all.txt` content follows `settings.ipsetMode`.

## Baseline measurement (engine)

Before testing strategies the engine measures target reachability with NO
bypass running (`StrategyEngine\Measure-Baseline`). If every URL target passes
all three suites, the network is unrestricted: the engine skips strategy
tests, stops any managed background winws and reports
`Network unrestricted - bypass not required`. The baseline row appears in
`status.allResults` as `(baseline: no bypass)` but is excluded from install
candidates, `greenStrategies`, and the monitor-loop strategy map — it carries
no bypass arguments and must never be installed.
Individual checks retry once on curl exit-28 (transient drops) before
verdicting ERR.

## ACL model (Preflight, when security.hardenAcls = true)

The project directory inherits `Authenticated Users: Modify` — any local
account could otherwise replace files that the SYSTEM engine executes.
Preflight audits and tightens (non-fatal on failure, warning in status):

- `zapret-core/bin`, `src`, `launcher`, `tray` → Administrators + SYSTEM
  FullControl; Users/Authenticated Users ReadAndExecute only.
- `state`, `settings.json` → keep user Modify (tray must write commands.json
  and widget geometry); strip other non-admin writers.
- `logs`, `reports` → user ReadAndExecute; engine write.
- Each path is checked first with `Get-Acl` (`Test-PathAclMatches`); `icacls`
  runs only when the protected explicit ACL differs from the target grants, so
  an already hardened tree costs no subtree walk at boot.

## Logging fallback

`logs/` is admin-only after hardening, while the unprivileged tray still
calls `Write-Log`. `Write-Log` therefore fails over to `state/tray.log`
(user-writable) when the primary write is denied, and never throws.
Reviewers: `state/tray.log` is tray-written diagnostics, not the engine log.

## Security markers (Wave 3a)

New log events introduced by hardening, searchable under module `Security`
or `Launcher`: `PayloadHash`, `PayloadRejected`, `ZipEntryRejected`,
`StagingAclSet`, `StagingAclFailed`, `AclHardened`, `AclHardenSkipped`,
`AclHardenFailed`, `InvalidEnumClamped`, `CommandOversize`;
`Launcher`: `WscriptMissing`, `VerifiedAction`, `VerifiedActionMismatch`,
`VerifiedActionUnavailable`, `ProjectRootInvalid`, `FallbackUsed`.

## Targets and scoring

- Targets are read from `zapret-core/utils/targets.txt`
  (`Key = "https://host"` or `Key = "PING:ip"`); fallback defaults are the
  Discord/YouTube/Google/Cloudflare set from `test zapret.ps1` when the file
  is missing.
- Per URL target three checks: HTTP/1.1, TLS1.2, TLS1.3 (curl.exe, timeout
  `test.curlTimeoutSec`). A completed exchange (`curl exit code = 0`) is OK,
  matching stock; HEAD responses such as 403/404 are still reachability proof.
  Actual HTTP codes are logged in `TargetResult codes`. PING targets are
  measured separately (1000 ms timeout).
- **Fully green**: every URL target answered OK on all three protocols.
  PING results are recorded but not part of the green condition.
- **Score** = total OK count (max `3 * urlTargetCount`); tie-break = lower
  `avgPingMs` over PING targets. Strategies with score 0 are excluded unless
  no strategy scored above 0.

## Module map

| Module | File | Exports (min) |
|---|---|---|
| Config | `src/Config.psm1` | Get-Config, Save-Config, Get-Root, Write-Log, Read-Status, Write-Status, Read-Command, Resolve-ZapretCore |
| Preflight | `src/Preflight.psm1` | Invoke-Preflight, Invoke-OptionsPreflight |
| Update | `src/UpdateManager.psm1` | Invoke-Update (returns $true when payload replaced → rerun pipeline) |
| Engine | `src/StrategyEngine.psm1` | Get-Strategies, Invoke-StrategyTests |
| Service | `src/ServiceManager.psm1` | Install-ZapretService, Remove-ZapretService, Get-ZapretServiceState, Enter-MonitorLoop |
| Notify | `src/Notify.psm1` | Send-TrayNotification, Write-Report |
| Orchestrator | `src/Autopilot.ps1` | phases: Boot → Update → Preflight → Test → Install → Monitor |

The SYSTEM engine is headless: it never creates WinForms controls or host UI.
`Show-TrayMessage` only logs the event; the interactive tray observes
`status.json` and owns balloons. The compiled dual-mode app is built with
PS2EXE `-noConsole -noOutput -noError` so stray host output cannot become a
modal dialog in session 0.

`ServiceManager` and its exported names are retained for compatibility. Service
functions manage only the engine-owned background process; `sc create` is not
used. The strategy `.bat` is the launch source for tests and active operation.

DEVLOG entries: `Area/module | Was | Now | Reason | Verified`.
