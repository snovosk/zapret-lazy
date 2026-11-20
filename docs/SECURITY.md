# Security model — zapret-lazy

zapret-lazy runs code at the highest privilege level on the machine
(a SYSTEM scheduled task creates and starts a Windows service). That makes it
a valuable target, so the attack surface is designed and checked explicitly.
This document is the threat model; rules are normative for code review.

## Assets and privilege boundaries

| Asset | Lives in | Written by | Executed/read by |
|---|---|---|---|
| Engine modules | `src/`, `launcher/` | developer | SYSTEM task (powershell imports them) |
| Service binaries | `zapret-core/bin/` | UpdateManager | SCM starts `winws.exe` as SYSTEM |
| Driver | `zapret-core/bin/WinDivert64.sys` | UpdateManager | kernel (signature-enforced by Windows) |
| Command channel | `state/commands.json` | tray (unprivileged user) | SYSTEM engine |
| Canonical config | `settings.json` | Config (tray writes widget geometry) | engine |
| Status channel | `state/status.json` | engine | tray |

Boundary A: unprivileged local user → SYSTEM engine (commands.json, any file
in the project tree the user can write). Boundary B: network → local tree
(release download). Boundary C: user input → service configuration.

## Threats and mitigations

1. **Local tampering with engine-owned files.** The project dir inherits
   `Authenticated Users: Modify`, so without hardening any local account can
   replace `winws.exe` or engine modules and achieve SYSTEM execution at next
   boot. Mitigation: Preflight ACL tightening (CONVENTIONS "ACL model") on
   every run; non-fatal warning if it fails, so the operator sees it.
2. **Tampered release download.** Mitigation: TLS 1.2+ only; pinned GitHub
   hosts, URLs never taken from config/state; zip-slip-safe extraction;
   Authenticode of `WinDivert64.sys` must be Valid (fail-closed); optional
   SHA256 pin of `winws.exe` via `security.pinSha256` (fail-closed);
   measured hash always logged/reported for comparison with upstream
   (bol-van/zapret releases); staging dir ACL-tightened; atomic swap with
   rollback; user lists never overwritten.
3. **Command channel abuse.** The tray is unprivileged, so commands are
   untrusted input. Impact is bounded by construction: `switch` only selects
   among strategies the engine itself tested and classified fully green,
   `retest` reruns the same pipeline, `shutdown` only exits the engine, and
   `setoption` accepts only two option names with case-sensitive value
   whitelists. Strategy names are restricted to general*.bat before .bat launch.
   No field of commands.json is ever
   executed, interpolated into a command line, or used as a path. Whitelist
   validation + 64 KB size cap; corrupt/oversized files are dropped.
4. **Config tampering.** `settings.json` is user-writable (the user owns the
   machine). Enum fields are clamped to whitelists on load
   (`InvalidEnumClamped` marker); no setting can inject a URL, path, or
   command.
5. **State file races / partial reads.** All JSON writes are atomic
   (temp file + move); readers tolerate corrupt files by dropping them.
6. **Service binary path hijacking.** `sc create` uses the absolute path
   inside `zapret-core/bin`; that directory is ACL-hardened (threat 1).
7. **Log injection / data exposure.** Logs contain markers, paths, versions,
   scores — never credentials or personal data. Tray/engine exchange only
   whitelisted fields.

## Residual risks (accepted, documented)

- The interactive user is a local administrator: admin = full control by
  design. The ACL model protects against *other* unprivileged accounts, not
  against the owner.
- `winws.exe` is unsigned upstream; without `security.pinSha256` its
  integrity relies on TLS + GitHub + the signed driver alongside it. Compare
  the logged SHA256 with the upstream release when first installing.
- GitHub/raw/release-download outages or filtering: update failure degrades
  gracefully to "keep current payload". Release asset resolution does not use
  the rate-limited unauthenticated GitHub API.
- WinDivert is legitimately flagged by some AVs (see upstream README). This
  is an operator decision, not something the software can fix.
- DoS: a local user can spam `retest` commands and churn the service. Impact
  is availability-only; acceptable for a single-user tool.

## Rules for future changes (code review gate)

- No new network endpoint without pinning it here and in CONVENTIONS.
- No new command verb without whitelist validation in ServiceManager.
- No execution of strings from any JSON file.
- No relaxed validation (no `-ErrorAction Ignore` on signature/hash checks).
- New persisted state needs an owner per the state ownership table.
