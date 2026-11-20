# TESTING — zapret-lazy

How every change in this repo is verified before it is called done. The
project ships **no automated test framework on purpose** (PowerShell 5.1,
no external modules): verification is a fixed ladder of repeatable checks
plus manual runtime runs. Results are recorded in `docs/DEVLOG.md` with the
`Verified` column using the levels below — never upgrade a level you did
not actually perform.

## Verification levels

| Level | Meaning |
|---|---|
| `code review` | read-through only; nothing executed. |
| `unit` | executed against fixtures/mocks; no network, no service changes, no scheduled tasks. |
| `integration` | executed on a dedicated admin test machine; real `zapret-core` payload, real service install/remove, scheduled tasks registered and removed. |
| `real network` | executed against live DPI-blocked targets (Discord/YouTube reachability through winws). |

Baseline environment for all levels: Windows 10/11, stock PowerShell 5.1
(`$PSVersionTable.PSVersion.Major -eq 5`), curl.exe present, project path
ASCII-only and outside OneDrive.

## Ladder 0 — static gates (every change, every module)

Run from the project root on the deliverable itself:

```powershell
# 1. Syntax: every .psm1 / .ps1 parses under PS 5.1 strict mode.
Get-ChildItem src, tray, launcher -Recurse -Include *.psm1, *.ps1 | ForEach-Object {
    $errs = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$errs)
    if ($errs) { throw "$($_.Name): $($errs.Count) parse errors" }
}

# 2. Exports match the module map in docs/CONVENTIONS.md.
Import-Module .\src\Config.psm1 -Force
# (repeat per module; compare (Get-Module <name>).ExportedFunctions.Keys
#  against the CONVENTIONS table)

# 3. No banned constructs: '??', ternary, ForEach-Object -Parallel, external modules.
Select-String -Path src\*, tray\*, launcher\* -Pattern '\?\?','-Parallel' -List
```

A change that fails any gate is not reviewed further.

## Ladder 1 — module checks (`unit`)

Fixture-based checks, runnable as throwaway scripts; they must not need admin.

- **Config**: `Get-Config` on a missing file creates defaults byte-identical
  to the schema in `docs/CONVENTIONS.md`; a partial config gains only the
  missing sections; `Save-Config` round-trips. Corrupt JSON -> defaults +
  `Config ConfigInvalid` in the log.
- **Strategy parsing (StrategyEngine.Get-Strategies)**: feed a fixture
  directory containing a trimmed copy of `general.bat` and one
  `general (ALT2).bat`; assert the produced name->args map equals a checked-in
  expected-args fixture per strategy — in particular: `--dpi-desync-fake-quic`
  path gets `\"...\"` quoting, `sni`/`host`/`altorder` merge with `=`,
  `%GameFilterTCP%`/`%GameFilterUDP%` become `12` (disabled) /
  `1024-65535` (all), `%BIN%`/`%LISTS%` point into `zapret-core\`.
- **Targets parsing**: fixture `targets.txt` with `Key = "https://host"`,
  `Key = "PING:1.1.1.1"`, blank/comment lines -> expected URL/PING split;
  missing file -> the documented Discord/YouTube/Google/Cloudflare fallback.
- **Scoring**: fixture result sets exercising the rules in
  `docs/CONVENTIONS.md`: full green vs partial, tie-break on lower
  `avgPingMs`, zero-score exclusion, "all zero -> keep best-effort list".
- **Command validation**: `switch` with a strategy outside `greenStrategies`
  is rejected and logged; `retest` and unknown commands are routed per spec;
  executed commands land in `commands.processed.json`.

## Ladder 2 — pipeline integration (`integration`)

On the admin test machine, payload present at `zapret-core\` (copy the
reference distribution for a repeatable baseline, then also test full
provisioning with an empty root):

1. Run `src/Autopilot.ps1` and confirm in `logs/autopilot-YYYYMMDD.log` the
   phase order `Boot -> Update -> Preflight -> Test -> Install -> Monitor`
   with `[ZAP-AUTO]` markers for every behavioral point listed in
   `docs/ARCHITECTURE.md` sections 3.1–3.6.
2. Confirm `state/status.json` is valid JSON at every poll while the engine
   runs (a poller script hammering `Read-Status` never throws).
3. Confirm the installed service: `sc query zapret` RUNNING, `sc qc zapret`
   binPath equals `\"<root>\zapret-core\bin\winws.exe\" <args of best green
   strategy>`, registry marker `zapret-discord-youtube` = strategy base name,
   `netsh interface tcp show global` timestamps enabled.
4. Hand-write `state\commands.json` (`switch` to a green strategy, then
   `retest`) and confirm the swap/reinstall and the Test->Install->Monitor
   rerun; confirm each command ends in `commands.processed.json`.
5. Update path: force it by seeding an older `zapret-core\.service\version.txt`;
   confirm download -> service stop -> payload swap -> user lists preserved
   (`lists\*-user.txt`, `ipset-all.txt`, `.backup` byte-identical) -> pipeline
   rerun -> `status.payloadVersion` bumped.
6. Failure paths: rename `bin\` away -> Preflight hard-fails with
   `phase: "error"` and a tray-readable message; restore and retest.

## Ladder 3 — regression against upstream (`real network`)

The scoring must agree with the upstream methodology on the same machine,
same hour:

- Run the reference `utils\test zapret.ps1` (standard mode, all configs) and
  zapret-lazy's Test phase.
- Per strategy, the OK/ERR/UNSUP counts must match; `greenStrategies[0]`
  should match the upstream "Best config" (allow a documented ping
  tie-break divergence).
- Watchdog behavior: stop the `zapret` service manually -> restart detected
  within `monitor.watchdogIntervalSec`; block ICMP -> `network.up: false`
  in status and no panic in the log.

## Ladder 4 — tray and installer (`integration`)

- Register both scheduled tasks (launcher), reboot, confirm the engine is
  running under SYSTEM before logon and the tray appears after logon.
- Tray shows phase/strategy from `status.json`; `switch` and `retest` menu
  items produce the documented commands; widget position survives restart.
- Uninstall removes tasks, service, WinDivert and leaves user lists in
  `zapret-core\lists\` intact.

## House rules

- Never register tasks, start winws or install the service outside the
  admin test machine used for Ladder 2/4 — unit-level work must stay
  side-effect-free.
- `git status` after every ladder run: delete scratch files the run created
  (keep logs only if a DEVLOG entry references them).
- Each run that changes behavior gets a DEVLOG row with the honest level.
