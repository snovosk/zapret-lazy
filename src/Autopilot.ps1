# Autopilot.ps1 - engine entry point and phase orchestrator for zapret-lazy.
# Runs hidden as SYSTEM via the ZapretLazyEngine scheduled task (launcher.vbs).
# Pipeline: Boot -> Update -> Preflight -> Test -> Install -> Monitor, looping
# back to Test when the tray requests a retest. See docs/CONVENTIONS.md and
# docs/ARCHITECTURE.md. Log marker module name: 'Autopilot'. Exports nothing.

Set-StrictMode -Version Latest
# PS2EXE -noConsole renders every Write-Progress (Expand-Archive, first-use
# module loading) as a separate white window: progress is never shown.
$ProgressPreference = 'SilentlyContinue'

# --- Named constants (no magic numbers) ---
$script:StateDirName = 'state'
$script:EngineLockFileName = 'engine.lock'
$script:StrategyHistoryFileName = 'strategy-history.json'
$script:RequiredDirs = @('state', 'logs', 'reports')
$script:PhaseBoot = 'boot'
$script:PhaseUpdate = 'update'
$script:PhasePreflight = 'preflight'
$script:PhaseTesting = 'testing'
$script:PhaseInstalling = 'installing'
$script:PhaseMonitoring = 'monitoring'
$script:PhaseError = 'error'
$script:PhasePaused = 'paused'
# VPN pause: route re-check cadence while waiting, heartbeat for the tray.
$script:VpnWaitPollMs = 1000
$script:VpnWaitHeartbeatSec = 10
# Resume only after the VPN route stayed away this long: a VPN client that is
# (re)connecting briefly hands the route back to the physical adapter.
$script:VpnResumeStableSec = 5
# Progress block stages (status.json progress.stage): a mirror of phase with
# 'done' for monitoring and an explicit 'error'; initial stage is 'boot'.
$script:ProgressStageBoot = 'boot'
$script:ProgressStageUpdate = 'update'
$script:ProgressStagePreflight = 'preflight'
$script:ProgressStageTesting = 'testing'
$script:ProgressStageInstalling = 'installing'
$script:ProgressStageDone = 'done'
$script:ProgressStageError = 'error'
# Strategy-test schedule (settings.testSchedule, CONVENTIONS): the gate window
# in hours for each non-'onboot' value; 0 means 'test at every engine start'.
$script:ScheduleOnBoot = 'onboot'
$script:ScheduleEvery3Days = 'every3days'
$script:ScheduleWeekly = 'weekly'
$script:ScheduleMonthly = 'monthly'
$script:ScheduleHoursEvery3Days = 72
$script:ScheduleHoursWeekly = 168
$script:ScheduleHoursMonthly = 720
$script:ConfigTestScheduleName = 'testSchedule'
# Skip-path service ensure matrix (see Repair-ZapretService).
$script:ZapretServiceName = 'zapret'
$script:WinwsProcessName = 'winws'
$script:ServiceStartTimeoutSec = 15
$script:ServicePollDelaySec = 1
# Maintenance while running (no reboot needed): schedule check every hour,
# payload update check every 24 h and after a wake; a wake after at least
# WakeGapSec counts as a new start for the 'onboot' schedule.
$script:MaintenanceIntervalSec = 3600
$script:UpdateCheckIntervalHours = 24
$script:WakeGapSec = 1800
$script:NetworkStillDownRetrySec = 30
$script:LastUpdateCheckUtc = $null
$script:MaintenanceTestDue = $null
$script:MaintenanceMessage = $null
# Quick boot: history of a run whose remembered strategy passed alone.
$script:QuickBootHistory = $null

function Get-UtcTimestamp {
    return (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
}

function Get-ResultProperty {
    # Strict-mode-safe property reader for engine result objects.
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name
    )
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-PayloadVersion {
    # Payload version from zapret-core\.service\version.txt with the
    # service.bat LOCAL_VERSION line as fallback (same sources UpdateManager
    # reads). $null when no payload is provisioned yet.
    $core = Resolve-ZapretCore
    $versionFile = Join-Path $core '.service\version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        try {
            $raw = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
            if ($raw -match '^\d+(\.\d+)*$') { return $raw }
            Write-Log 'Autopilot' 'PayloadVersionInvalid' "path=$versionFile content=$raw"
        } catch {
            Write-Log 'Autopilot' 'PayloadVersionReadFailed' "path=$versionFile error=$($_.Exception.Message)"
        }
    }
    $serviceBat = Join-Path $core 'service.bat'
    if (Test-Path -LiteralPath $serviceBat) {
        try {
            $match = [regex]::Match((Get-Content -LiteralPath $serviceBat -Raw -Encoding UTF8), 'LOCAL_VERSION=([0-9][0-9.]*)')
            if ($match.Success) { return $match.Groups[1].Value }
        } catch {
            Write-Log 'Autopilot' 'PayloadVersionReadFailed' "path=$serviceBat error=$($_.Exception.Message)"
        }
    }
    return $null
}

function Test-ProcessAlive {
    param([Parameter(Mandatory = $true)][int]$ProcessId)
    if ($ProcessId -le 0) { return $false }
    try {
        $process = [System.Diagnostics.Process]::GetProcessById($ProcessId)
        try { $process.Dispose() } catch { }
        return $true
    } catch [System.ArgumentException] {
        return $false   # no process with this id: stale lock owner
    } catch {
        return $true    # exists but not queryable: never steal another engine's lock
    }
}

function Resolve-EngineLock {
    # Single-instance guard. Returns @{ Acquired; OwnerPid }: Acquired $true
    # when this process owns the lock afterwards; OwnerPid set when another
    # live engine holds it. A stale (dead or unparseable) lock is overwritten.
    param([Parameter(Mandatory = $true)][string]$LockPath)
    $result = @{ Acquired = $false; OwnerPid = 0 }
    if (Test-Path -LiteralPath $LockPath) {
        $ownerPid = 0
        try {
            $raw = (Get-Content -LiteralPath $LockPath -Raw -Encoding UTF8).Trim()
            [void][int]::TryParse($raw, [ref]$ownerPid)
        } catch {
            $ownerPid = 0
        }
        if (($ownerPid -gt 0) -and ($ownerPid -ne $PID) -and (Test-ProcessAlive -ProcessId $ownerPid)) {
            $result.OwnerPid = $ownerPid
            return $result
        }
        Write-Log 'Autopilot' 'StaleLock' "ownerPid=$ownerPid pid=$PID"
    }
    [System.IO.File]::WriteAllText($LockPath, "$PID", (New-Object System.Text.UTF8Encoding($false)))
    $result.Acquired = $true
    return $result
}

function New-InitialStatus {
    # Status object with every CONVENTIONS schema field present from the start.
    # phase values: boot|update|preflight|testing|installing|monitoring|paused|error.
    # vpn: { active, name } - paused while the internet route uses a VPN tunnel.
    # progress: boot-time progress block for the tray status line; strategy is
    # the strategy file under test (1-based index), $null outside testing.
    # gameFilterMode/ipsetMode expose the engine config to the widget option
    # steppers (design: game filter / ipset list fields).
    param(
        [AllowEmptyString()][string]$ServiceState,
        [AllowNull()][string]$PayloadVersion,
        [AllowEmptyString()][string]$GameFilterMode,
        [AllowEmptyString()][string]$IpsetMode
    )
    return [pscustomobject]@{
        updatedAt       = (Get-UtcTimestamp)
        phase           = $script:PhaseBoot
        activeStrategy  = $null
        serviceState    = $ServiceState
        payloadVersion  = $PayloadVersion
        gameFilterMode  = $GameFilterMode
        ipsetMode       = $IpsetMode
        network         = [pscustomobject]@{ up = $null; samples = @() }
        greenStrategies = @()
        allResults      = @()
        lastTestAt      = $null
        message         = $null
        vpn             = [pscustomobject]@{ active = $false; name = $null }
        progress        = [pscustomobject]@{ stage = $script:ProgressStageBoot; strategy = $null; index = 0; total = 0 }
    }
}

function Sync-Status {
    # Stamp updatedAt and write state/status.json atomically via Write-Status.
    $script:Status.updatedAt = (Get-UtcTimestamp)
    Write-Status -Status $script:Status
}

function Update-Progress {
    # Sets the status.json progress block (stage/strategy/index/total) on a
    # stage transition. Tolerant of a Status object without a progress block:
    # one is grafted on so writers stay StrictMode-safe. Defaults reset
    # strategy to $null and the counters to 0 on every non-testing transition.
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('boot', 'update', 'preflight', 'testing', 'installing', 'done', 'error')]
        [string]$Stage,
        # Untyped on purpose: a [string] parameter would coerce $null to ''
        # (PS 5.1), breaking the schema's strategy=null contract.
        [AllowNull()]$Strategy = $null,
        [int]$Index = 0,
        [int]$Total = 0
    )
    if ($null -eq $script:Status) { return }
    if (-not $script:Status.PSObject.Properties['progress']) {
        $script:Status | Add-Member -MemberType NoteProperty -Name progress -Value ([pscustomobject]@{ stage = $script:ProgressStageBoot; strategy = $null; index = 0; total = 0 })
    }
    $script:Status.progress.stage = $Stage
    $script:Status.progress.strategy = $Strategy
    $script:Status.progress.index = $Index
    $script:Status.progress.total = $Total
}

function Wait-VpnInactive {
    # VPN pause: while the internet route goes through a VPN tunnel zapret is
    # useless and strategy tests would measure the tunnel, so the managed winws
    # is stopped and the engine waits. Returns immediately when no VPN is up.
    # Only 'shutdown' is honoured while paused; other tray commands are dropped
    # (the widget shows the paused state and its pending selections expire).
    param([Parameter(Mandatory = $true)]$Config)
    $vpn = Get-VpnState
    if (-not $vpn.Active) { return }

    try { Remove-ZapretService | Out-Null } catch {
        Write-Log 'Autopilot' 'ServiceRemoveFailed' "error=$($_.Exception.Message)"
    }
    Set-StatusDefaults -Status $script:Status
    $displayOnlyStrategy = $false
    if ([string]::IsNullOrWhiteSpace([string]$script:Status.activeStrategy)) {
        # Paused before any test this boot: show the remembered strategy in the
        # widget instead of "(no green strategies)". Display only - cleared on
        # resume, the engine then runs the test gate (quick boot) as usual.
        $pausedHistory = Read-StrategyHistory
        if ($null -ne $pausedHistory -and -not [string]::IsNullOrEmpty([string]$pausedHistory.LastStrategy)) {
            $script:Status.greenStrategies = @($pausedHistory.LastGreen)
            $script:Status.activeStrategy = [string]$pausedHistory.LastStrategy
            $displayOnlyStrategy = $true
        }
    }
    $script:Status.phase = $script:PhasePaused
    $script:Status.serviceState = 'paused'
    $script:Status.vpn = [pscustomobject]@{ active = $true; name = [string]$vpn.Name }
    $script:Status.message = 'VPN active - zlazy paused'
    Update-Progress -Stage $script:ProgressStageDone
    Sync-Status
    Write-Log 'Autopilot' 'VpnPaused' "adapter=$($vpn.Name)"

    $targets = @()
    if ($Config.monitor.pingTargets) { $targets = @($Config.monitor.pingTargets) }
    $heartbeat = [System.Diagnostics.Stopwatch]::StartNew()
    $offFor = New-Object System.Diagnostics.Stopwatch
    while ($true) {
        Start-Sleep -Milliseconds $script:VpnWaitPollMs
        $command = Read-Command
        if ($null -ne $command -or (Test-Path -LiteralPath (Join-Path (Get-Root) 'state\commands.json'))) {
            $verb = $null
            if ($null -ne $command -and $command.PSObject.Properties['command']) { $verb = $command.command }
            Move-CommandToProcessed
            if ($verb -is [string] -and $verb -ceq 'shutdown') {
                Write-Log 'Service' 'CommandShutdown' 'paused=vpn'
                Write-Log 'Autopilot' 'Exit' "pid=$PID code=0"
                exit 0
            }
            Write-Log 'Autopilot' 'CommandDropped' "reason=vpnPaused"
        }
        $vpn = Get-VpnState
        if ($vpn.Active) {
            if ($offFor.IsRunning) { Write-Log 'Autopilot' 'VpnFlap' "offMs=$($offFor.ElapsedMilliseconds)" }
            $offFor.Reset()
        } else {
            if (-not $offFor.IsRunning) { $offFor.Start() }
            if ($offFor.Elapsed.TotalSeconds -ge $script:VpnResumeStableSec) { break }
        }
        if ($heartbeat.Elapsed.TotalSeconds -ge $script:VpnWaitHeartbeatSec) {
            $heartbeat.Restart()
            try {
                $sample = Measure-NetworkSample -Targets $targets
                $script:Status.network.up = $sample.up
                $script:Status.network.samples = $sample.samples
            } catch { }
            Sync-Status
        }
    }
    $script:Status.vpn = [pscustomobject]@{ active = $false; name = $null }
    if ($displayOnlyStrategy) {
        $script:Status.activeStrategy = $null
        $script:Status.greenStrategies = @()
    }
    $script:Status.serviceState = 'none'
    $script:Status.message = 'VPN off - resuming'
    Sync-Status
    Write-Log 'Autopilot' 'VpnResumed'
}

function Wait-NetworkReady {
    # Blocks until DNS + HTTPS to GitHub work (Preflight Invoke-NetworkWait,
    # 120 s per round) - forever if needed: at a cold boot Wi-Fi may come up
    # late, and without network neither the update check nor the tests mean
    # anything. Never exits the engine; honours a tray 'shutdown'.
    $round = 0
    while ($true) {
        if (Invoke-NetworkWait) { return }
        $round++
        $script:Status.message = 'Waiting for network'
        Sync-Status
        Write-Log 'Autopilot' 'NetworkStillDown' "round=$round"
        $command = Read-Command
        if ($null -ne $command) {
            $verb = $null
            if ($command.PSObject.Properties['command']) { $verb = $command.command }
            Move-CommandToProcessed
            if ($verb -is [string] -and $verb -ceq 'shutdown') {
                Write-Log 'Service' 'CommandShutdown' 'waiting=network'
                Write-Log 'Autopilot' 'Exit' "pid=$PID code=0"
                exit 0
            }
            Write-Log 'Autopilot' 'CommandDropped' 'reason=networkDown'
        }
        Start-Sleep -Seconds $script:NetworkStillDownRetrySec
    }
}

function Test-ScheduleDue {
    # Maintenance gate: 'onboot' is due only after a wake (a new start for the
    # user); other schedules when the history age reaches their window.
    param([Parameter(Mandatory = $true)]$Config, [bool]$Wake)
    $schedule = $script:ScheduleOnBoot
    if ($Config.PSObject.Properties[$script:ConfigTestScheduleName] -and $Config.testSchedule) { $schedule = [string]$Config.testSchedule }
    if ($schedule -eq $script:ScheduleOnBoot) { return $Wake }
    return (Test-NeedStrategyTest -History (Read-StrategyHistory) -Schedule $schedule)
}

function Show-TrayMessage {
    # The SYSTEM engine is headless. The interactive tray observes status.json
    # and owns notifications; never create WinForms controls in this process.
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateSet('Info', 'Warning', 'Error')][string]$Icon
    )
    Write-Log 'Autopilot' 'Notification' "icon=$Icon message=$Message"
}

# ---------------------------------------------------------------------------
# Strategy memory and test schedule (CONVENTIONS "Strategy memory and test
# schedule"): engine-owned state\strategy-history.json keeps the chosen
# strategy across reboots; settings.testSchedule decides how often the engine
# re-runs the test phase instead of keeping the remembered strategy.
# ---------------------------------------------------------------------------

function Read-StrategyHistory {
    # Reads state\strategy-history.json into a normalized object:
    # @{ LastStrategy; LastGreen; TestedAt }. $null when the file is missing or
    # fails schema validation (callers then run the full test path). testedAt
    # is parsed to a UTC [datetime]; a missing/unparseable stamp keeps the
    # object but forces a retest via Test-NeedStrategyTest.
    $path = Join-Path (Join-Path (Get-Root) $script:StateDirName) $script:StrategyHistoryFileName
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    $raw = $null
    try {
        $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log 'Autopilot' 'StrategyHistoryInvalid' "path=$path error=$($_.Exception.Message)"
        return $null
    }
    if ($null -eq $raw) {
        Write-Log 'Autopilot' 'StrategyHistoryInvalid' "path=$path reason=Empty"
        return $null
    }
    $lastStrategy = $null
    $lastStrategyProp = $raw.PSObject.Properties['lastStrategy']
    if ($null -ne $lastStrategyProp -and $null -ne $lastStrategyProp.Value) {
        if ($lastStrategyProp.Value -is [string]) {
            $lastStrategy = $lastStrategyProp.Value
        } else {
            Write-Log 'Autopilot' 'StrategyHistoryInvalid' "path=$path reason=lastStrategyType"
            return $null
        }
    }
    $lastGreen = New-Object System.Collections.Generic.List[string]
    $lastGreenProp = $raw.PSObject.Properties['lastGreen']
    if ($null -ne $lastGreenProp -and $null -ne $lastGreenProp.Value) {
        if ($lastGreenProp.Value -is [array]) {
            foreach ($entry in @($lastGreenProp.Value)) {
                if ($entry -is [string]) { $lastGreen.Add($entry) }
            }
        } else {
            Write-Log 'Autopilot' 'StrategyHistoryInvalid' "path=$path reason=lastGreenType"
            return $null
        }
    }
    $testedAt = $null
    $testedAtProp = $raw.PSObject.Properties['testedAt']
    if ($null -ne $testedAtProp -and -not [string]::IsNullOrEmpty([string]$testedAtProp.Value)) {
        $parsed = $null
        try {
            $parsed = [datetime]::Parse([string]$testedAtProp.Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        } catch {
            $parsed = $null
        }
        if ($null -ne $parsed) {
            $testedAt = $parsed
        } else {
            Write-Log 'Autopilot' 'StrategyHistoryInvalid' "path=$path reason=testedAt value='$($testedAtProp.Value)'"
        }
    }
    return [pscustomobject]@{ LastStrategy = $lastStrategy; LastGreen = $lastGreen.ToArray(); TestedAt = $testedAt }
}

function Write-StrategyHistory {
    # Atomic write of state\strategy-history.json after a successful install.
    param(
        [AllowNull()][AllowEmptyString()][string]$LastStrategy,
        [AllowEmptyCollection()][string[]]$GreenNames
    )
    $path = Join-Path (Join-Path (Get-Root) $script:StateDirName) $script:StrategyHistoryFileName
    $green = New-Object System.Collections.Generic.List[string]
    if ($GreenNames) {
        foreach ($name in @($GreenNames)) {
            if ($name -is [string]) { $green.Add($name) }
        }
    }
    $payload = [pscustomobject]@{
        lastStrategy = $LastStrategy
        lastGreen    = $green.ToArray()
        testedAt     = (Get-UtcTimestamp)
    }
    $tmp = "$path.tmp"
    try {
        ($payload | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Force $tmp $path
        Write-Log 'Autopilot' 'StrategyHistoryWritten' "path=$path strategy=$LastStrategy green=$($green.Count)"
    } catch {
        Write-Log 'Autopilot' 'StrategyHistoryWriteFailed' "path=$path error=$($_.Exception.Message)"
    }
}

function Set-RememberedStrategy {
    # Manual switch from the widget: the chosen strategy becomes lastStrategy
    # until the next test. lastGreen and testedAt are kept as they are, so the
    # test schedule is not shifted; the next quick boot verifies this choice
    # first and keeps it while it stays fully green. Atomic write.
    param([Parameter(Mandatory = $true)][string]$Name)
    $path = Join-Path (Join-Path (Get-Root) $script:StateDirName) $script:StrategyHistoryFileName
    $history = Read-StrategyHistory
    $green = @()
    $testedAt = $null
    if ($null -ne $history) {
        $green = @($history.LastGreen)
        if ($null -ne $history.TestedAt) { $testedAt = $history.TestedAt.ToString("yyyy-MM-ddTHH:mm:ss'Z'") }
    } elseif ($null -ne $script:Status) {
        $green = @($script:Status.greenStrategies | Where-Object { $_ -is [string] })
    }
    $payload = [pscustomobject]@{
        lastStrategy = $Name
        lastGreen    = [string[]]$green
        testedAt     = $testedAt
    }
    $tmp = "$path.tmp"
    ($payload | ConvertTo-Json -Depth 4) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $path
    Write-Log 'Autopilot' 'ManualStrategyRemembered' "strategy=$Name testedAt=$testedAt"
}

function Get-ScheduleHours {
    # Gate window in hours for a schedule value; 0 = no window (test every start).
    param([Parameter(Mandatory = $true)][string]$Schedule)
    switch ($Schedule) {
        $script:ScheduleEvery3Days { return $script:ScheduleHoursEvery3Days }
        $script:ScheduleWeekly { return $script:ScheduleHoursWeekly }
        $script:ScheduleMonthly { return $script:ScheduleHoursMonthly }
        default { return 0 }
    }
}

function Test-NeedStrategyTest {
    # $true when the test phase must run: 'onboot' always; otherwise when the
    # history is missing/invalid, testedAt is absent/unparseable, or the testedAt
    # age reaches the schedule window (72/168/720 h).
    param(
        [AllowNull()]$History,
        [Parameter(Mandatory = $true)][string]$Schedule
    )
    if ($Schedule -eq $script:ScheduleOnBoot) { return $true }
    $windowHours = Get-ScheduleHours -Schedule $Schedule
    if ($windowHours -le 0) { return $true }
    if ($null -eq $History) { return $true }
    if ($null -eq $History.TestedAt) { return $true }
    $age = (Get-Date).ToUniversalTime() - $History.TestedAt
    if ($age.TotalHours -ge $windowHours) { return $true }
    return $false
}

function Get-NaturalSortKey {
    # Digits padded to 8 chars, exactly like StrategyEngine's Get-Strategies sort.
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Regex]::Replace($Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') })
}

function Get-OrderedStrategies {
    # TEST-path order (CONVENTIONS): remembered strategy first, then the
    # remaining history greens in recorded order, then everything else; natural
    # sort within each group, no duplicates, history names not on disk dropped.
    param(
        [Parameter(Mandatory = $true)][array]$Strategies,
        [AllowNull()]$History
    )
    $onDisk = @{}
    foreach ($item in @($Strategies)) {
        $name = [System.IO.Path]::GetFileName("$item")
        $onDisk[$name] = $item
    }
    $groups = New-Object System.Collections.Generic.List[object]
    if ($null -ne $History -and -not [string]::IsNullOrEmpty([string]$History.LastStrategy)) {
        $groups.Add(@([string]$History.LastStrategy))
    }
    $greenGroup = New-Object System.Collections.Generic.List[string]
    if ($null -ne $History -and $null -ne $History.LastGreen) {
        foreach ($entry in @($History.LastGreen)) {
            if (($entry -is [string]) -and -not [string]::IsNullOrEmpty($entry)) { $greenGroup.Add($entry) }
        }
    }
    $groups.Add($greenGroup.ToArray())

    $ordered = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($group in $groups) {
        $sortedGroup = @($group | Sort-Object { Get-NaturalSortKey -Name $_ })
        foreach ($name in $sortedGroup) {
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            if ($onDisk.ContainsKey($name)) { $ordered.Add($onDisk[$name]) }
        }
    }
    $rest = @()
    foreach ($name in $onDisk.Keys) {
        if (-not $seen.ContainsKey($name)) { $rest += $name }
    }
    foreach ($name in @($rest | Sort-Object { Get-NaturalSortKey -Name $_ })) {
        $ordered.Add($onDisk[$name])
    }
    return $ordered.ToArray()
}

function Test-WinwsProcessAlive {
    try {
        return (@(Get-Process -Name $script:WinwsProcessName -ErrorAction SilentlyContinue).Count -gt 0)
    } catch {
        return $false
    }
}

function Wait-ZapretServiceRunning {
    # Polls the service state until 'running' or ServiceStartTimeoutSec elapses.
    $deadline = (Get-Date).AddSeconds($script:ServiceStartTimeoutSec)
    $state = 'unknown'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $script:ServicePollDelaySec
        try { $state = Get-ZapretServiceState } catch { $state = 'unknown' }
        if ($state -eq 'running') { break }
    }
    return $state
}

function Repair-ZapretService {
    # Ensure the remembered background process is alive; no SCM operations.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$StrategyName,
        [AllowEmptyCollection()][string[]]$ArgumentList
    )
    $state = 'unknown'
    try { $state = Get-ZapretServiceState } catch { }
    if ($state -eq 'running') {
        Write-Log 'Autopilot' 'KeepServiceHealthy' "strategy=$StrategyName mode=background"
        return 'running'
    }
    Write-Log 'Autopilot' 'KeepServiceInstall' "strategy=$StrategyName mode=background"
    if (Install-ZapretService -Config $Config -StrategyName $StrategyName -ArgumentList $ArgumentList) { return 'running' }
    try { return Get-ZapretServiceState } catch { return 'unknown' }
}

function Resolve-StrategyKeep {
    # SKIP-path probe. Returns @{ Keep; Strategy; Green; Arguments; StrategyMap }:
    # Keep=$false sends the caller to the full test path (remembered .bat gone
    # or unparseable against the current payload). The StrategyMap is rebuilt
    # by re-parsing each green strategy against the CURRENT payload; greens
    # whose .bat vanished stay in Green (status) but are skipped from the map.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$History,
        [Parameter(Mandatory = $true)][string]$Schedule
    )
    $result = @{ Keep = $false; Strategy = $null; Green = @(); Arguments = @(); StrategyMap = $null }
    $remembered = [string]$History.LastStrategy
    if ([string]::IsNullOrEmpty($remembered)) { return $result }
    $core = Resolve-ZapretCore
    $rememberedBat = Join-Path $core $remembered
    if (-not (Test-Path -LiteralPath $rememberedBat)) {
        Write-Log 'Autopilot' 'KeepBatMissing' "strategy=$remembered schedule=$Schedule"
        return $result
    }
    $rememberedArgs = @(Get-WinwsArguments -BatPath $rememberedBat -Config $Config)
    if ($rememberedArgs.Count -eq 0) {
        Write-Log 'Autopilot' 'KeepArgsEmpty' "strategy=$remembered schedule=$Schedule"
        return $result
    }
    $strategyMap = @{}
    $green = New-Object System.Collections.Generic.List[string]
    foreach ($name in @($History.LastGreen)) {
        if (-not ($name -is [string]) -or [string]::IsNullOrEmpty($name)) { continue }
        $green.Add($name)
        $bat = Join-Path $core $name
        if (-not (Test-Path -LiteralPath $bat)) {
            Write-Log 'Autopilot' 'KeepGreenBatMissing' "strategy=$name"
            continue
        }
        $strategyMap[$name] = @(Get-WinwsArguments -BatPath $bat -Config $Config)
    }
    $strategyMap[$remembered] = $rememberedArgs
    $result.Keep = $true
    $result.Strategy = $remembered
    $result.Green = $green.ToArray()
    $result.Arguments = $rememberedArgs
    $result.StrategyMap = $strategyMap
    return $result
}

$script:Status = $null
$script:LockPath = $null
$script:LockOwned = $false

trap {
    $fatalMessage = $_.Exception.Message
    if (Test-Path function:\Write-Log) {
        Write-Log 'Autopilot' 'FatalError' "error=$fatalMessage"
    }
    if ($null -ne $script:Status) {
        try {
            $script:Status.phase = 'error'
            $script:Status.message = $fatalMessage
            Update-Progress -Stage $script:ProgressStageError
            $script:Status.updatedAt = (Get-UtcTimestamp)
            Write-Status -Status $script:Status
        } catch {
            if (Test-Path function:\Write-Log) {
                Write-Log 'Autopilot' 'FatalStatusWriteFailed' "error=$($_.Exception.Message)"
            }
        }
    }
    if (Test-Path function:\Send-TrayNotification) {
        Show-TrayMessage -Message "Fatal error: $fatalMessage" -Icon Error
    }
    exit 1
}

function Invoke-ZlazyEngine {
try {
    # --- (0) Import all Wave-1 modules (launcher already bypassed policy) ---
    $moduleFiles = @(
        'Config.psm1',
        'Preflight.psm1',
        'UpdateManager.psm1',
        'StrategyEngine.psm1',
        'ServiceManager.psm1',
        'Notify.psm1'
    )
    foreach ($moduleFile in $moduleFiles) {
        Import-Module (Join-Path $PSScriptRoot $moduleFile) -ErrorAction Stop | Out-Null
    }

    # --- Boot: directories, config, engine lock, initial status ---
    $root = Get-Root
    foreach ($dirName in $script:RequiredDirs) {
        New-Item -ItemType Directory -Path (Join-Path $root $dirName) -Force | Out-Null
    }

    $cfg = Get-Config

    $script:LockPath = Join-Path (Join-Path $root $script:StateDirName) $script:EngineLockFileName
    $lock = Resolve-EngineLock -LockPath $script:LockPath
    if (-not $lock.Acquired) {
        Write-Log 'Autopilot' 'AlreadyRunning' "ownerPid=$($lock.OwnerPid) pid=$PID"
        exit 0
    }
    $script:LockOwned = $true
    Write-Log 'Autopilot' 'Boot' "pid=$PID root=$root"

    # A shutdown written while no engine was running must not kill the next boot.
    $pendingCommand = Read-Command
    if ($null -ne $pendingCommand -and $pendingCommand.PSObject.Properties['command'] -and $pendingCommand.command -eq 'shutdown') {
        Remove-Item -LiteralPath (Join-Path $root 'state\commands.json') -Force -ErrorAction SilentlyContinue
        Write-Log 'Autopilot' 'StaleShutdownDropped'
    }

    $bootServiceState = 'unknown'
    try { $bootServiceState = Get-ZapretServiceState } catch { }
    $script:Status = New-InitialStatus -ServiceState $bootServiceState -PayloadVersion (Get-PayloadVersion) `
        -GameFilterMode ([string]$cfg.gameFilterMode) -IpsetMode ([string]$cfg.ipsetMode)
    $script:Status.message = 'Boot'
    Sync-Status
    Write-Log 'Autopilot' 'Phase' "phase=$script:PhaseBoot"

    # --- Phase loop. Boot/Update run once per process start; Invoke-Update
    #     replacing the payload restarts the pipeline from preflight; a tray
    #     retest loops to testing, while setoption reapplies the active strategy. ---
    $retest = $false
    $forceFullTest = $false
    $applyOptionsOnly = $false
    $nextPhase = $script:PhaseUpdate
    do {
        if ($nextPhase -eq $script:PhaseUpdate) {
            $script:Status.phase = $script:PhaseUpdate
            $script:Status.message = 'Checking for updates'
            Update-Progress -Stage $script:ProgressStageUpdate
            Sync-Status
            Write-Log 'Autopilot' 'Phase' "phase=$script:PhaseUpdate"
            # Network first: at a cold boot the engine starts before Wi-Fi.
            Wait-NetworkReady
            $script:Status.message = 'Checking for updates'
            Sync-Status
            $replaced = Invoke-Update -Config $cfg
            $script:LastUpdateCheckUtc = (Get-Date).ToUniversalTime()
            if ($replaced) {
                $cfg = Get-Config
                $script:Status.payloadVersion = (Get-PayloadVersion)
                Write-Log 'Autopilot' 'UpdateApplied' "payloadVersion=$($script:Status.payloadVersion)"
            }
            $nextPhase = $script:PhasePreflight
            if ($null -ne $script:MaintenanceTestDue) {
                # Maintenance update check: without a new payload and without a
                # due test the running strategy simply keeps working.
                $maintenanceTest = [bool]$script:MaintenanceTestDue
                $script:MaintenanceTestDue = $null
                if ((-not $replaced) -and (-not $maintenanceTest)) {
                    $script:Status.message = $script:MaintenanceMessage
                    $nextPhase = $script:PhaseMonitoring
                }
            }
        }

        if ($nextPhase -eq $script:PhasePreflight) {
            $script:Status.phase = $script:PhasePreflight
            $script:Status.message = 'Preflight checks'
            Update-Progress -Stage $script:ProgressStagePreflight
            Sync-Status
            Write-Log 'Autopilot' 'Phase' 'phase=preflight'
            # Maintenance/wake can reach preflight directly: never let a slow
            # network turn into an engine exit.
            Wait-NetworkReady
            $script:Status.message = 'Preflight checks'
            if (-not (Invoke-Preflight -Config $cfg)) {
                $script:Status.phase = $script:PhaseError
                $script:Status.message = 'Preflight failed'
                Update-Progress -Stage $script:ProgressStageError
                Sync-Status
                Write-Log 'Autopilot' 'PreflightFailed'
                Show-TrayMessage -Message 'Preflight failed' -Icon Warning
                exit 1
            }
            if ($applyOptionsOnly) { $nextPhase = $script:PhaseInstalling } else { $nextPhase = $script:PhaseTesting }
        }

        if ($nextPhase -eq $script:PhaseTesting) {
            # Tests through a VPN tunnel would rank the tunnel, not the bypass.
            Wait-VpnInactive -Config $cfg
            $script:Status.phase = $script:PhaseTesting

            # Strategy memory + test schedule gate (CONVENTIONS): the schedule
            # comes from settings.json via Get-Config at engine start. A fresh
            # enough history keeps the remembered strategy without re-testing.
            $testSchedule = $script:ScheduleOnBoot
            if ($cfg.PSObject.Properties[$script:ConfigTestScheduleName] -and $cfg.testSchedule) {
                $testSchedule = [string]$cfg.testSchedule
            }
            $history = Read-StrategyHistory
            $needTest = Test-NeedStrategyTest -History $history -Schedule $testSchedule
            $manualRetest = $forceFullTest
            if ($forceFullTest) {
                $needTest = $true
                $forceFullTest = $false
                Write-Log 'Autopilot' 'ManualRetestForced'
            }
            Write-Log 'Autopilot' 'TestSchedule' "schedule=$testSchedule needTest=$needTest"

            $keep = $null
            if ((-not $needTest) -and ($null -ne $history) -and (-not [string]::IsNullOrEmpty([string]$history.LastStrategy))) {
                $keep = Resolve-StrategyKeep -Config $cfg -History $history -Schedule $testSchedule
            }

            if (($null -ne $keep) -and $keep.Keep) {
                # SKIP path: no Invoke-StrategyTests and no Write-Report; keep
                # the remembered strategy, ensure the service, go to monitoring.
                $strategyMap = $keep.StrategyMap
                $script:Status.activeStrategy = $keep.Strategy
                $script:Status.greenStrategies = $keep.Green
                $script:Status.message = "Keeping $($keep.Strategy) (schedule $testSchedule)"
                Update-Progress -Stage $script:ProgressStageDone
                $keepServiceState = Repair-ZapretService -Config $cfg -StrategyName $keep.Strategy -ArgumentList $keep.Arguments
                $script:Status.serviceState = $keepServiceState
                Sync-Status
                Write-Log 'Autopilot' 'TestSkipped' "strategy=$($keep.Strategy) schedule=$testSchedule service=$keepServiceState"
                $nextPhase = $script:PhaseMonitoring
            } else {
                if ($null -ne $keep) {
                    Write-Log 'Autopilot' 'TestFallback' "reason=keepUnavailable schedule=$testSchedule"
                }
                $script:Status.message = 'Testing strategies'
                Write-Log 'Autopilot' 'Phase' "phase=$script:PhaseTesting"

                $strategies = @(Get-OrderedStrategies -Strategies (Get-Strategies) -History $history)
                if ($null -ne $history) {
                    Write-Log 'Autopilot' 'StrategiesReordered' "remembered=$($history.LastStrategy) count=$($strategies.Count)"
                }
                $strategyCount = @($strategies).Count
                Write-Log 'Autopilot' 'TestStart' "strategies=$strategyCount"
                Update-Progress -Stage $script:ProgressStageTesting -Total $strategyCount
                Sync-Status

                $rawResults = $null
                $results = New-Object System.Collections.Generic.List[object]
                $script:BaselineNoBypass = $false
                $script:QuickBootHistory = $null
                # A VPN coming up mid-run makes every further probe measure the
                # tunnel: abort, pause, and restart the test gate afterwards.
                $vpnAbortCheck = { [bool](Get-VpnState).Active }
                $testsAborted = $false
                try {
                if ($strategyCount -gt 0) {
                    $targets = Get-Targets
                    # Baseline: with an unrestricted network no bypass is the most
                    # comfortable option — strategies only intercept and can only
                    # degrade reachability that is already complete.
                    $urlTargetCount = @($targets | Where-Object { $_.Url }).Count
                    if ($urlTargetCount -gt 0) {
                        Update-Progress -Stage $script:ProgressStageTesting -Strategy '(baseline: no bypass)' -Index 0 -Total 0
                        Sync-Status
                        $baseline = Measure-Baseline -Config $cfg -Targets $targets
                        if (& $vpnAbortCheck) { throw (New-Object System.OperationCanceledException 'zlazy-test-aborted') }
                        $results.Add($baseline)
                        if ($baseline.fullyGreen) {
                            $script:BaselineNoBypass = $true
                            Write-Log 'Autopilot' 'BaselineGreen' 'network-unrestricted: strategy tests skipped'
                        }
                    }
                    if (-not $script:BaselineNoBypass) {
                        # Per-strategy boot progress: the engine fires this scriptblock
                        # before each strategy start; each fire does a cheap atomic
                        # Write-Status so the tray status line advances 0..N.
                        $progressCallback = {
                            param($Index, $Total, $Name)
                            if ($null -eq $script:Status) { return }
                            Update-Progress -Stage $script:ProgressStageTesting -Strategy ([string]$Name) -Index ([int]$Index) -Total ([int]$Total)
                            Sync-Status
                        }
                        # Quick boot: on a scheduled (not manual) test, verify the
                        # remembered strategy alone first. Fully green -> keep it
                        # and skip the other strategies, so the bypass is up in
                        # seconds instead of after the whole 20+ strategy sweep.
                        $quickName = $null
                        if ((-not $manualRetest) -and ($null -ne $history) -and (-not [string]::IsNullOrEmpty([string]$history.LastStrategy))) {
                            $firstName = [System.IO.Path]::GetFileName("$($strategies[0])")
                            if ($firstName -eq [string]$history.LastStrategy) { $quickName = $firstName }
                        }
                        $remaining = $strategies
                        if ($null -ne $quickName) {
                            $quickResults = @(Invoke-StrategyTests -Config $cfg -Strategies @($strategies[0]) -Targets $targets -OnStrategyStart $progressCallback -ShouldAbort $vpnAbortCheck)
                            if ($quickResults.Count -gt 0 -and $quickResults[0].fullyGreen) {
                                $script:QuickBootHistory = $history
                                $remaining = @()
                                Write-Log 'Autopilot' 'QuickBootHit' "strategy=$quickName ok=$($quickResults[0].ok)"
                            } else {
                                Write-Log 'Autopilot' 'QuickBootMiss' "strategy=$quickName"
                                $remaining = @($strategies | Select-Object -Skip 1)
                            }
                            foreach ($item in $quickResults) { $results.Add($item) }
                        }
                        if (@($remaining).Count -gt 0) {
                            $rawResults = Invoke-StrategyTests -Config $cfg -Strategies $remaining -Targets $targets -OnStrategyStart $progressCallback -ShouldAbort $vpnAbortCheck
                            if ($rawResults) {
                                foreach ($item in $rawResults) { $results.Add($item) }
                            }
                            if ($null -ne $quickName) {
                                # Merge the quick row into the full ranking.
                                $baselineRows = @($results | Where-Object { [string]$_.strategy -eq '(baseline: no bypass)' })
                                $ranked = @(Get-RankedStrategyResults -Results @($results | Where-Object { [string]$_.strategy -ne '(baseline: no bypass)' }))
                                $results = New-Object System.Collections.Generic.List[object]
                                foreach ($item in $baselineRows) { $results.Add($item) }
                                foreach ($item in $ranked) { $results.Add($item) }
                            }
                        }
                    }
                }
                } catch [System.OperationCanceledException] {
                    $testsAborted = $true
                }
                if ($testsAborted) {
                    Write-Log 'Autopilot' 'TestAborted' 'reason=vpn'
                    Wait-VpnInactive -Config $cfg
                    # Same request again (a manual retest stays a full retest).
                    $forceFullTest = $manualRetest
                    $script:QuickBootHistory = $null
                    $nextPhase = $script:PhaseTesting
                    $retest = $true
                    continue
                }

                # status.allResults: the six CONVENTIONS schema fields only; the
                # engine's Arguments NoteProperty must never reach status.json.
                # The baseline row is diagnostic display only — it must never
                # become an install candidate (it has no bypass arguments).
                $schemaRows = New-Object System.Collections.Generic.List[object]
                foreach ($item in $results) {
                    $schemaRows.Add(($item | Select-Object strategy, ok, err, unsup, avgPingMs, fullyGreen))
                }
                $script:Status.allResults = $schemaRows.ToArray()

                $greenNames = New-Object System.Collections.Generic.List[string]
                foreach ($item in $results) {
                    if ($item.fullyGreen -and [string]$item.strategy -ne '(baseline: no bypass)') { $greenNames.Add([string]$item.strategy) }
                }
                if ($null -ne $script:QuickBootHistory) {
                    # Quick boot tested one strategy: keep the previous greens
                    # (still on disk) available for switching in the widget.
                    foreach ($prevGreen in @($script:QuickBootHistory.LastGreen)) {
                        $prevName = [string]$prevGreen
                        if ([string]::IsNullOrEmpty($prevName) -or $greenNames.Contains($prevName)) { continue }
                        if (Test-Path -LiteralPath (Join-Path (Resolve-ZapretCore) $prevName)) { $greenNames.Add($prevName) }
                    }
                }
                $script:Status.greenStrategies = $greenNames.ToArray()
                $script:Status.lastTestAt = (Get-UtcTimestamp)

                if ($results.Count -gt 0) {
                    $reportChosen = '(none)'
                    foreach ($item in $results) {
                        if ([string]$item.strategy -ne '(baseline: no bypass)') { $reportChosen = [string]$item.strategy; break }
                    }
                    try {
                        Write-Report -Results $results -ChosenStrategy $reportChosen -Config $cfg | Out-Null
                    } catch {
                        Write-Log 'Autopilot' 'ReportFailed' "error=$($_.Exception.Message)"
                    }
                } else {
                    Write-Log 'Autopilot' 'NoStrategies'
                }
                Sync-Status
                $nextPhase = $script:PhaseInstalling
            }
        }

        if ($nextPhase -eq $script:PhaseInstalling -and $applyOptionsOnly) {
            $applyOptionsOnly = $false
            $script:Status.phase = $script:PhaseInstalling
            $script:Status.message = 'Applying options'
            Update-Progress -Stage $script:ProgressStageInstalling
            Sync-Status
            Invoke-OptionsPreflight -Config $cfg
            $activeName = [string]$script:Status.activeStrategy
            $script:Status.gameFilterMode = [string]$cfg.gameFilterMode
            $script:Status.ipsetMode = [string]$cfg.ipsetMode
            if ([string]::IsNullOrWhiteSpace($activeName)) {
                try { $script:Status.serviceState = Get-ZapretServiceState } catch { $script:Status.serviceState = 'unknown' }
                $script:Status.message = 'Network unrestricted - bypass not required'
                Update-Progress -Stage $script:ProgressStageDone
                Write-Log 'Autopilot' 'OptionsApplied' 'strategy=none'
            } else {
                try {
                    $batPath = Join-Path (Resolve-ZapretCore) $activeName
                    $optionArgs = @(Get-WinwsArguments -BatPath $batPath -Config $cfg)
                    if ($optionArgs.Count -eq 0) { throw "No parsed arguments for $activeName" }
                    $strategyMap = @{}
                    foreach ($greenName in $script:Status.greenStrategies) {
                        $greenBat = Join-Path (Resolve-ZapretCore) ([string]$greenName)
                        if (Test-Path -LiteralPath $greenBat) {
                            $strategyMap[[string]$greenName] = @(Get-WinwsArguments -BatPath $greenBat -Config $cfg)
                        }
                    }
                    $strategyMap[$activeName] = $optionArgs
                    if (-not (Install-ZapretService -Config $cfg -StrategyName $activeName -ArgumentList $optionArgs)) {
                        throw "Service reinstall failed for $activeName"
                    }
                    $script:Status.serviceState = 'running'
                    $activeOk = $null
                    foreach ($row in $script:Status.allResults) {
                        if ([string]$row.strategy -eq $activeName) { $activeOk = [int]$row.ok; break }
                    }
                    if ($null -ne $activeOk) { $script:Status.message = "Active: $activeName - $activeOk checks OK" }
                    else { $script:Status.message = "Active: $activeName" }
                    Update-Progress -Stage $script:ProgressStageDone
                    Write-Log 'Autopilot' 'OptionsApplied' "strategy=$activeName gameFilter=$($cfg.gameFilterMode) ipset=$($cfg.ipsetMode)"
                } catch {
                    $script:Status.phase = $script:PhaseError
                    $script:Status.message = "Option apply failed: $activeName"
                    Update-Progress -Stage $script:ProgressStageError
                    Write-Log 'Autopilot' 'OptionsApplyFailed' "strategy=$activeName error=$($_.Exception.Message)"
                }
            }
            Sync-Status
            $nextPhase = $script:PhaseMonitoring
        }

        if ($nextPhase -eq $script:PhaseInstalling) {
            $script:Status.phase = $script:PhaseInstalling
            $script:Status.message = 'Installing service'
            Update-Progress -Stage $script:ProgressStageInstalling
            Sync-Status
            Write-Log 'Autopilot' 'Phase' "phase=$script:PhaseInstalling"

            # Strategy-name -> arguments map for all tested strategies (the
            # baseline row excluded — display only, never installable). The
            # monitor loop resolves tray 'switch' commands against it via
            # ContainsKey()/indexer. A plain hashtable is required: on PS 5.1
            # (.NET Framework) OrderedDictionary has no ContainsKey method, so
            # [ordered]@{} would break ServiceManager's switch validation.
            $strategyMap = @{}
            foreach ($item in $results) {
                if ([string]$item.strategy -eq '(baseline: no bypass)') { continue }
                $mapArguments = Get-ResultProperty $item 'Arguments'
                if ($null -eq $mapArguments) { $mapArguments = @() }
                $strategyMap[[string]$item.strategy] = @($mapArguments)
            }
            if ($null -ne $script:QuickBootHistory) {
                foreach ($greenName in @($script:Status.greenStrategies)) {
                    $greenName = [string]$greenName
                    if ($strategyMap.ContainsKey($greenName)) { continue }
                    $greenArgs = @(Get-WinwsArguments -BatPath (Join-Path (Resolve-ZapretCore) $greenName) -Config $cfg)
                    if ($greenArgs.Count -gt 0) { $strategyMap[$greenName] = $greenArgs }
                }
                $script:QuickBootHistory = $null
            }

            $candidates = New-Object System.Collections.Generic.List[object]
            foreach ($item in $results) {
                if ([string]$item.strategy -eq '(baseline: no bypass)') { continue }
                $candidates.Add($item)
            }

            $anyPositive = $false
            foreach ($item in $candidates) {
                if ([int]$item.ok -gt 0) { $anyPositive = $true; break }
            }

            if ($script:BaselineNoBypass) {
                # The network reached every target without any bypass: the most
                # comfortable choice is no interception at all. Remove a previous
                # bypass install so an invasive strategy cannot degrade traffic.
                try { Remove-ZapretService | Out-Null } catch {
                    Write-Log 'Autopilot' 'ServiceRemoveFailed' "error=$($_.Exception.Message)"
                }
                try { $script:Status.serviceState = Get-ZapretServiceState } catch { $script:Status.serviceState = 'unknown' }
                $script:Status.activeStrategy = $null
                $script:Status.message = 'Network unrestricted - bypass not required'
                Update-Progress -Stage $script:ProgressStageDone
                Sync-Status
                Write-StrategyHistory -LastStrategy $null -GreenNames @()
                Write-Log 'Autopilot' 'BypassNotInstalled' 'network-unrestricted'
                Show-TrayMessage -Message 'Network unrestricted - bypass not required' -Icon Info
            }
            elseif (($candidates.Count -eq 0) -or (-not $anyPositive)) {
                $script:Status.phase = $script:PhaseError
                $script:Status.activeStrategy = $null
                $script:Status.message = 'No working strategy'
                Update-Progress -Stage $script:ProgressStageError
                Sync-Status
                Write-Log 'Autopilot' 'NoWorkingStrategy' "results=$($results.Count)"
                Show-TrayMessage -Message 'No working strategy' -Icon Warning
            } else {
                $chosen = $candidates[0]
                $chosenName = [string]$chosen.strategy
                $chosenArgs = Get-ResultProperty $chosen 'Arguments'
                if ($null -eq $chosenArgs) { $chosenArgs = @() }
                $installed = Install-ZapretService -Config $cfg -StrategyName $chosenName -ArgumentList $chosenArgs
                if ($installed) {
                    $script:Status.activeStrategy = $chosenName
                    $script:Status.serviceState = 'running'
                    $script:Status.payloadVersion = (Get-PayloadVersion)
                    $script:Status.message = "Active: $chosenName - $($chosen.ok) checks OK"
                    Sync-Status
                    Write-StrategyHistory -LastStrategy $chosenName -GreenNames $script:Status.greenStrategies
                    Write-Log 'Autopilot' 'Installed' "strategy=$chosenName ok=$($chosen.ok)"
                    Show-TrayMessage -Message "Active: $chosenName" -Icon Info
                } else {
                    $installState = 'unknown'
                    try { $installState = Get-ZapretServiceState } catch { }
                    $script:Status.phase = $script:PhaseError
                    $script:Status.serviceState = $installState
                    $script:Status.message = "Install failed: $chosenName"
                    Update-Progress -Stage $script:ProgressStageError
                    Sync-Status
                    Write-Log 'Autopilot' 'InstallFailed' "strategy=$chosenName"
                    Show-TrayMessage -Message "Install failed: $chosenName" -Icon Warning
                }
            }
            $nextPhase = $script:PhaseMonitoring
        }

        if ($nextPhase -eq $script:PhaseMonitoring) {
            $script:Status.phase = $script:PhaseMonitoring
            Update-Progress -Stage $script:ProgressStageDone
            Sync-Status
            Write-Log 'Autopilot' 'Phase' "phase=$script:PhaseMonitoring"
            $loopResult = Enter-MonitorLoop -Config $cfg -Status $script:Status -StrategyMap $strategyMap `
                -MaintenanceIntervalSec $script:MaintenanceIntervalSec -WakeGapSec $script:WakeGapSec `
                -OnStrategySwitched { param($Name) Set-RememberedStrategy -Name ([string]$Name) }
            if ($null -ne $loopResult -and $loopResult.Retest) {
                $applyOptionsOnly = [bool](Get-ResultProperty $loopResult 'ApplyOptions')
                if ([bool](Get-ResultProperty $loopResult 'Maintenance')) {
                    $applyOptionsOnly = $false
                    $cfg = Get-Config
                    $wake = [bool](Get-ResultProperty $loopResult 'Wake')
                    $updateDue = $wake -or ($null -eq $script:LastUpdateCheckUtc) -or `
                        (((Get-Date).ToUniversalTime() - $script:LastUpdateCheckUtc).TotalHours -ge $script:UpdateCheckIntervalHours)
                    if ($cfg.PSObject.Properties['updateCheck'] -and $cfg.updateCheck -eq $false) { $updateDue = $false }
                    $testDue = Test-ScheduleDue -Config $cfg -Wake $wake
                    Write-Log 'Autopilot' 'Maintenance' "wake=$wake updateDue=$updateDue testDue=$testDue"
                    if ($updateDue) {
                        $script:MaintenanceTestDue = $testDue
                        $script:MaintenanceMessage = $script:Status.message
                        $nextPhase = $script:PhaseUpdate
                    } elseif ($testDue) {
                        $nextPhase = $script:PhasePreflight
                    } else {
                        $nextPhase = $script:PhaseMonitoring
                    }
                } elseif ([bool](Get-ResultProperty $loopResult 'VpnPause')) {
                    Wait-VpnInactive -Config $cfg
                    $cfg = Get-Config
                    if ([string]::IsNullOrWhiteSpace([string]$script:Status.activeStrategy)) {
                        # Nothing was active (no bypass needed / none chosen): re-run the test gate.
                        $applyOptionsOnly = $false
                        $nextPhase = $script:PhaseTesting
                    } else {
                        # Restart the strategy that ran before the VPN came up.
                        $applyOptionsOnly = $true
                        $nextPhase = $script:PhaseInstalling
                    }
                } elseif ($applyOptionsOnly) {
                    $cfg = Get-Config
                    $nextPhase = $script:PhaseInstalling
                    Write-Log 'Autopilot' 'OptionsRequested'
                } else {
                    $forceFullTest = $true
                    $nextPhase = $script:PhaseTesting
                    Write-Log 'Autopilot' 'RetestRequested'
                }
                $retest = $true
            } else {
                Write-Log 'Autopilot' 'MonitorEnded' 'reason=loopReturned'
                $retest = $false
            }
        }
    } while ($retest)

    Write-Log 'Autopilot' 'Exit' "pid=$PID code=0"
    exit 0
} finally {
    if ($script:LockOwned) {
        try { Remove-ZapretService | Out-Null } catch { Write-Log 'Autopilot' 'ShutdownCleanupFailed' "error=$($_.Exception.Message)" }
        if ($null -ne $script:Status) {
            try {
                $script:Status.serviceState = 'none'
                $script:Status.message = 'zlazy stopped'
                Sync-Status
            } catch { }
        }
    }
    if ($script:LockOwned -and $script:LockPath -and (Test-Path -LiteralPath $script:LockPath)) {
        try {
            Remove-Item -LiteralPath $script:LockPath -Force -ErrorAction Stop
            Write-Log 'Autopilot' 'LockReleased' "pid=$PID"
        } catch {
            Write-Log 'Autopilot' 'LockReleaseFailed' "error=$($_.Exception.Message)"
        }
    }
}
}

Invoke-ZlazyEngine
