# ARCHITECTURE — zapret-lazy

Technical design of the autonomous zapret manager. The normative contracts
(state schemas, scoring, log markers, module map) live in
`docs/CONVENTIONS.md` — this document explains how the pieces fit together and
must not contradict it. Behavioral facts about the upstream utility come from
`service.bat`, `general.bat` and `utils\test zapret.ps1` of the Flowseal
zapret-discord-youtube distribution.

Target platform: Windows 10/11, PowerShell 5.1 only, no external modules.
curl.exe and schtasks are the only external tools relied upon.

## 1. Two-process architecture

The system is split into two processes because payload/driver control requires
elevation while the UI must live in the interactive user session. They never
talk in-process — all coordination goes through JSON files in `state/`. The
engine owns a background winws process; no permanent zapret service is created.

### 1.1 Engine (scheduled task, SYSTEM, highest run level)

- Preferred entry point: `zlazy.exe --engine` (the same binary also contains
  the tray). Script fallback: `src/Autopilot.ps1` through launcher.vbs.
- Scheduled task `ZapretLazyEngine` (registered by
  `launcher\Register-LazyTasks.ps1`): trigger AtStartup, principal SYSTEM,
  RunLevel Highest, unlimited execution time. Tray independently starts at logon.
- The engine is the only process allowed to touch managed `winws.exe`,
  WinDivert, legacy service removal, `netsh` and payload files.
- Single instance: on start, Autopilot takes a PID lock at
  `state/engine.lock`; if another live engine owns it, the new instance logs
  `Autopilot AlreadyRunning` and exits. The scheduled task may fire while a
  previous run is still monitoring.

### 1.2 Tray (scheduled task, user context)

- Preferred entry point: `zlazy.exe --tray` (default when no mode is passed);
  script fallback: `tray\TrayApp.ps1`. Scheduled task `ZapretLazyTray`:
  trigger AtLogon (current user, 10 s delay), principal interactive user,
  RunLevel Limited — the tray needs no admin.
- Runs in the interactive session, so it can draw a tray icon, show toasts
  and read the user's display language. It polls `state/status.json`
  (`monitor.commandPollMs`, default 1000 ms) and renders phase, active
  strategy, service state and the human-readable `message` field.
- The primary UI is a compact dark widget card (orange accents and fox brand):
  strategy/game-filter/ipset steppers, status glyph + summary line, network
  latency row, test-schedule dropdown, and a "⋮" action menu (retest, open
  logs/reports, show/hide, exit). The tray icon carries the same state as a
  badge. The widget auto-shows at logon to display check progress and auto-hides
  when done (per-boot, not persisted).
- The tray sends commands by atomically writing `state/commands.json`
  (temp file + move). It persists widget geometry and test schedule through
  `Save-Config`; game-filter/ipset changes use the validated `setoption`
  command. The tray never touches winws or the driver directly.
- "Exit" sends `shutdown`: engine stops managed winws and exits, then the tray
  exits. Hiding/closing only the widget leaves the application running.
  Uninstall additionally removes both tasks and legacy services.

### 1.3 Why files instead of pipes or TCP

Both processes are independent scheduled tasks with different security
contexts; a file-based mailbox is the only coupling that works across
logon/logoff, survives either side crashing, and is trivially inspectable by
support (`state/` is human-readable). Atomicity is achieved by writing to a
`.tmp` sibling and moving over the target, so readers never see partial JSON.

## 2. State map and ownership

Ownership is defined in `docs/CONVENTIONS.md`; the data flow is:

```
                    settings.json (Config.psm1 / Save-Config only)
                   ^                                       |
        tray reads (widget/test/monitor knobs)            v
 tray saves widget/schedule; engine saves validated setoption

 engine (ServiceManager)                    tray (TrayApp.ps1)
   |  Write-Status state/status.json  ------>  Read-Status (poll)
   |  Read-Command state/commands.json <------ Write (atomic, single object)
   +--> moves executed command to state/commands.processed.json (diagnostics)
```

Invariants that the code must keep:

- `settings.json` is written **only** through `Save-Config`. The tray persists
  widget geometry and test schedule; the engine writes only the two whitelisted
  options after validating a `setoption` command.
- `state/status.json` is written **only** by the engine, always atomically
  (already enforced by `Write-Status`). Tray treats a missing/corrupt file as
  "engine offline".
- `state/commands.json` holds exactly one command object. The engine reads it
  inside the monitor loop, executes it, then moves the file to
  `state/commands.processed.json` (overwriting). Unknown commands are logged
  (`Service UnknownCommand`) and dropped. A malformed file is treated as
  absent (`Read-Command` logs `Config CommandCorrupt`).
- Derived data (reports in `reports/`, logs in `logs/autopilot-YYYYMMDD.log`)
  never feeds back into canonical state.
- All log lines use the `[ZAP-AUTO]` marker with format
  `[ZAP-AUTO] <timestamp> <Module> <Event> key=value` via `Write-Log`.
  The `<Module>` token is the module name from the CONVENTIONS module map
  (`Config`, `Preflight`, `Update`, `Engine`, `Service`, `Notify`); the
  orchestrator script `src/Autopilot.ps1` logs as `Autopilot`.

## 3. Pipeline phases (engine, src/Autopilot.ps1)

`Boot -> Update -> Preflight -> Test -> Install -> Monitor`, then the process
stays inside `Enter-MonitorLoop`. `Invoke-Update` returning `$true` (payload
replaced) restarts the pipeline from Preflight (Boot work — config, lock,
initial status — is not redone).

Maintenance (see CONVENTIONS "Maintenance while running"): the engine waits
for the network before the update check and before preflight instead of
exiting, re-checks payload updates every 24 h and after a wake, and applies
the test schedule hourly and after a wake without a reboot.

VPN pause (`Wait-VpnInactive`): before Test and on every monitor poll tick the
engine checks whether the internet route uses a VPN tunnel (`Get-VpnState`).
If so it stops its winws and stays in `phase: paused` until the VPN is gone,
then restarts the previous strategy (or re-enters Test when none was active).
See CONVENTIONS `status.json` → `vpn`.

### 3.1 Boot

Resolve project root (`Get-Root`), load config (`Get-Config`), create
`state/`, `logs/`, `reports/`, take the engine lock, log `Autopilot Boot`.
Resolve the payload directory (`Resolve-ZapretCore` -> `<root>\zapret-core`).
Write initial `status.json` (`phase: "boot"`).

### 3.2 Update (src/UpdateManager.psm1, `Invoke-Update`)

Mirrors `service.bat :service_check_updates` but automated:

1. Skip when `settings.json updateCheck` is `$false` (upstream equivalent:
   `utils\check_updates.enabled` absent / `NO_UPDATE_CHECK`).
2. Fetch `https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt`
   (`Invoke-RestMethod`, 10 s timeout, `Cache-Control: no-cache`, TLS 1.2+
   enforced). Failure is non-fatal: log `Update UpdateFailed stage=versionCheck`
   and return `$false`.
3. Compare with the local payload version read from
   `zapret-core\.service\version.txt` (fallback: `LOCAL_VERSION` in
   `service.bat`; release zips ship no `.service/` folder, so the fallback is
   the primary source in practice). Missing local payload counts as
   "no version" and triggers provisioning.
4. On newer remote version: construct the official release asset URL directly
   from the validated numeric version (`releases/download/<version>/…zip`),
   without the rate-limited GitHub API; download into a staging directory next
   to `zapret-core` (same volume, so the final swap is a rename), extract
   zip-slip-safely, verify payload integrity (Authenticode of
   `WinDivert64.sys`, optional `security.pinSha256` of `winws.exe`), stop the
   `zapret` service if present, swap the payload per section 4 (user lists and
   `game_filter.enabled` preserved), return `$true` so Autopilot reruns the
   pipeline from Preflight against the new payload.

### 3.3 Preflight (src/Preflight.psm1, `Invoke-Preflight`)

Automates the checks from `service.bat :service_diagnostics` that can be
checked/fixed unattended, in this order. Every check gets a log marker;
hard failures return a structured result that lets Autopilot decide between
`phase: "error"` with a user-visible message and an auto-fix retry.

| Check | Auto-fix | Hard fail |
|---|---|---|
| Network up (DNS + HTTPS to GitHub) | 5 s retry loop, 120 s budget | yes |
| `zapret-core\bin\winws.exe` + `WinDivert64.sys` present | re-provision payload (Update phase) | yes |
| Stray `winws.exe` processes | kill | no |
| Conflicting bypass services (`GoodbyeDPI`, `discordfix_zapret`, `winws1`, `winws2`, `WinDivert14`, and `WinDivert` only while no winws runs) | `net stop` + `sc delete` (unattended equivalent of `service.bat` diagnostics) | no |
| TCP timestamps (`netsh interface tcp show global`) | `netsh interface tcp set global timestamps=enabled` | no |
| User lists (`*-user.txt` triplet) | create with upstream defaults when missing | no |
| `gameFilterMode` / `ipsetMode` vs payload flag files | align `utils\game_filter.enabled` and `lists\ipset-all.txt` | no |
| ACL hardening of engine-owned tree | `Protect-EngineTree` (when `security.hardenAcls`) | no (warning) |

Not automated in v1 (operator's responsibility, see README): Base Filtering
Engine state, system proxy, Adguard/Killer/Intel Connectivity/Check Point/
SmartByte/VPN conflicts, DoH setup, hosts-file pollution, Cyrillic/OneDrive
path warnings.

### 3.4 Test (src/StrategyEngine.psm1, `Get-Strategies`, `Invoke-StrategyTests`)

Reproduces `utils\test zapret.ps1` (standard mode) without user interaction:

1. `Get-Strategies` scans `zapret-core` for `*.bat` excluding `service*`,
   natural-sorted (`Regex::Replace name, '(\d+)', PadLeft(8)` — same rule as
   upstream), and parses
   each file with the `service.bat :service_install` algorithm: start
   capturing at the line containing `winws.exe`; tokenize; drop `^`/`^^`;
   wrap quoted args containing `:` in `\"...\"`; rewrite `@file` to
   `\"<zapret-core>\file\"`; rewrite bare file names to `\"<zapret-core>\file\"`;
   merge `--*` value lists and `sni`/`host`/`altorder` with `=`/`,`. Result:
   an **ordered strategy-name -> arguments string** map, with `%BIN%` /
   `%LISTS%` replaced by `zapret-core\bin\` / `zapret-core\lists\` and
   `%GameFilterTCP%` / `%GameFilterUDP%` replaced per `gameFilterMode`
   (`disabled` -> `12`, `all`/`tcp`/`udp` -> `1024-65535` for the respective
   filters, mirroring `service.bat :game_switch_status`).
2. `ipsetMode` / `gameFilterMode` are applied to the payload in the Preflight
   phase (3.3), not here: tests measure the configuration the user actually
   runs, so results reflect real usage (deviation from the upstream test
   script, which forces `ipset any` for DPI runs only).
3. Per strategy: stop stray `winws.exe`, launch the stock strategy `.bat`
   through `cmd.exe /d /c` with `NO_UPDATE_CHECK=1`, wait for winws up to
   `test.winwsReadyTimeoutMs` (5000 ms), and skip on timeout. Parsed arguments
   remain in the result map for validation/history, not for direct execution.
4. Per target from `zapret-core\utils\targets.txt` (`Key = "https://host"` or
   `Key = "PING:ip"`; fallback to the Discord/YouTube/Google/Cloudflare
   default set when missing), run through a `[runspacefactory]` pool capped
   at `test.maxParallel` (16): three curl.exe probes per URL target
   (`--http1.1`, `--tlsv1.2 --tls-max 1.2`, `--tlsv1.3 --tls-max 1.3`, all
   `-I -s -m <curlTimeoutSec> --connect-timeout <min(2,timeout)> -o NUL -w %{http_code}`),
   and a `System.Net.NetworkInformation.Ping` with 1000 ms timeout for every
   target's ping host. UNSUP detection mirrors the original stderr/exit-35
   patterns. Curl exit 0 is OK exactly like stock, including HEAD 403/404;
   actual response codes are logged. PS 5.1: the pool is `[powershell]::Create()` + `BeginInvoke`/
   `EndInvoke`, never `ForEach-Object -Parallel`.
5. Scoring per `docs/CONVENTIONS.md`: score = total OK count, tie-break =
   lower `avgPingMs` over PING targets, "fully green" = every URL target OK
   on all three protocols; PING results recorded but not part of green.
   Zero-score strategies excluded unless none scored. Output:
   `greenStrategies` (names, best first) plus `allResults`.
6. `Write-Report` (src/Notify.psm1) saves a human-readable summary to
   `reports\report-YYYYMMDD-HHmmss.txt`; status.json gets
   `phase: "testing"` -> `lastTestAt`, `allResults`, `greenStrategies`.

### 3.5 Background start (ServiceManager, compatibility name Install-ZapretService)

1. Pick the best-scoring result. Fully-green status is not required for a
   best-effort choice; fully-green candidates form the tray switchable set.
   Zero-working strategies produce phase `error`.
2. Remove a legacy `zapret` service if present and stop the currently managed
   winws. No `sc create` or auto-start service registration occurs.
3. Validate the strategy filename, set `NO_UPDATE_CHECK=1`, and launch its stock
   `.bat` through `cmd.exe /d /c`. Poll for a winws whose ExecutablePath is
   exactly `zapret-core\bin\winws.exe`, then log `Service ProcessStarted`.
4. Update status: `activeStrategy`, legacy `serviceState` (`running`/`none`)
   and message. The engine owns the process until shutdown.

TCP timestamps and `ipsetMode` are handled in Preflight. `Remove-ZapretService`
stops only the managed payload winws, removes legacy service entries, and
releases WinDivert when no other winws remains.

### 3.6 Monitor (src/ServiceManager.psm1, `Enter-MonitorLoop`)

Contract for the integrator (Autopilot):

```powershell
Enter-MonitorLoop -Config <obj> -Status <obj> -StrategyMap <IDictionary>
```

- `-StrategyMap` is the **in-memory strategy-name → arguments-array map built
  by Autopilot in the Test phase** (plain hashtable: PS 5.1
  `OrderedDictionary` lacks `ContainsKey`, so a plain hashtable is used — the
  consumer does key lookups only). The monitor loop never re-scans or
  re-parses the payload, so a `switch` command uses exactly the tested args.
- Loop body: each `monitor.watchdogIntervalSec` (10 s) cycle is chunked into
  `monitor.commandPollMs` (1000 ms) sleeps; `Read-Command` is polled every
  chunk. After the wait:
  - **Watchdog**: ping `monitor.pingTargets`; `Get-ZapretServiceState` checks
    the managed winws path. If it is absent during monitoring and the active
    strategy is in StrategyMap, start its stock `.bat` and log WatchdogRestart.
  - **Status**: `Write-Status` every pass end (with `updatedAt` UTC), not only
    on change — the tray's 2 s widget timer relies on fresh timestamps.
  - **Commands**: `Read-Command`; when present, handled inside try/finally so
    the command file is always moved to `state/commands.processed.json`:
    - `switch`: validated strictly (verb whitelist, strategy is a string ≤260
      chars, present in `Status.greenStrategies` **and** in `-StrategyMap`);
      on success `Install-ZapretService` with those args, update
      `activeStrategy`/`message`, log `Service CommandSwitch result=installed`;
      on any validation failure log `Service CommandRejected` /
      `CommandSwitch result=rejected reason=...` and keep the current
      strategy.
    - `retest`: log `Service CommandRetest`, **return from the loop** with
      `@{Retest=$true}` so Autopilot reruns Test → Install → Monitor in the
      same process.
    - `setoption`: validate raw string option/value against fixed whitelists
      (`gameFilterMode`, `ipsetMode`), persist via `Save-Config`, update status,
      then run Preflight → reinstall active strategy → Monitor. Test is skipped.
    - `shutdown`: return Retest=false; the engine's owning finally block stops
      managed winws, updates status and releases the PID lock.
    - Unknown/corrupt/oversized (>64 KB): logged (`CommandRejected` /
      `Config CommandOversize`) and dropped.
- `Get-ZapretServiceState` is a legacy name: `running` means managed winws is
  alive, `none` means no such process. It does not call `sc query`.

## 4. Payload management (`zapret-core/`)

The payload is the Flowseal zapret-discord-youtube release content, owned and
refreshed by the engine, stored under `<project root>\zapret-core\`
(`Resolve-ZapretCore`):

```
zapret-core\
  bin\            winws.exe, WinDivert64.sys, *.bin fake/pattern files
  lists\          list-*.txt, ipset-*.txt (+ ipset-all.txt.backup)
  utils\          targets.txt (consumed read-only), .service\
  .service\       version.txt (payload version marker)
  *.bat           strategy files (general*.bat), parsed by Get-Strategies
```

- **Provisioning**: first run with no `zapret-core` (or an incomplete one —
  no `bin\winws.exe`) downloads the official Flowseal release zip by the
  version-specific `releases/download` URL and extracts it in place. No manual
  "download zapret" step or GitHub API request is needed.
- **Updates**: full-directory swap of everything except user data (below).
  `bin\` and non-user `lists\` come from the release as-is; upstream version
  is read back from the new `zapret-core\.service\version.txt`.
- **User data preserved across updates** (the `service.bat :load_user_lists`
  triplet, plus the ipset list and its backup):
  `lists\ipset-exclude-user.txt`, `lists\list-general-user.txt`,
  `lists\list-exclude-user.txt`, `lists\ipset-all.txt`,
  `lists\ipset-all.txt.backup`. Missing `*-user.txt` files are re-created
  with the upstream defaults (`203.0.113.113/32`, `# Never leave this file
  empty`, `domain.example.abc`).
- **Never edited by autopilot**: the hosts file (upstream only offers a
  manual helper), `bin\*.bin` fake replacement (a deliberate user action in
  upstream; out of scope for v1).
- Path requirements inherited from upstream: ASCII-only path, not under
  OneDrive (checked in Preflight).

## 5. Configuration surface

Everything user-tunable is in `settings.json` (schema version 1, defined in
`docs/CONVENTIONS.md`): `gameFilterMode`, `ipsetMode`, `updateCheck`,
`test.*` timeouts/parallelism, `monitor.*` watchdog and ping targets,
`widget.*` tray window position, `security.pinSha256` /
`security.hardenAcls` (see `docs/SECURITY.md`). The tray directly edits widget
geometry and test schedule; game-filter/ipset steppers send validated
`setoption` commands, which the engine persists. Other knobs ship with sane
defaults and are documented in README.md.

## 6. Failure and recovery model

- Every phase transition and every external command failure produces a
  `[ZAP-AUTO]` log line; the tray mirrors the last engine `message`.
- Network unavailable at Boot/Update: update check is skipped, pipeline
  continues with the local payload.
- Test phase finds zero working strategies: no background process is started,
  `phase: "error"`, tray offers retest.
- Engine crash/reboot: the AtStartup task relaunches it. Update/Preflight run at
  every start; test history and testSchedule decide whether to keep or retest.
  A manual Retest forces Test → background start → Monitor regardless of schedule.
- Corrupt/missing state files: `Read-Status`/`Read-Command` return `$null`
  and log; the writer rebuilds them on the next tick. Partial JSON is
  impossible by construction (temp + move).
