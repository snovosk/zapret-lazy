# ServiceManager.psm1 — managed background winws lifecycle, watchdog and tray
# commands. Export names are retained for compatibility; no service is created.
# See docs/CONVENTIONS.md. Log marker module name: 'Service'.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# Named constants (no magic numbers).
$script:ServiceName = 'zapret'
$script:ServiceDisplayName = 'zapret'
$script:ServiceDescription = 'Zapret DPI bypass software'
$script:StrategyRegKey = 'HKLM\System\CurrentControlSet\Services\zapret'
$script:StrategyRegValue = 'zapret-discord-youtube'
$script:WinDivertServiceName = 'WinDivert'
$script:WinDivert14ServiceName = 'WinDivert14'
$script:WinwsImageName = 'winws.exe'
$script:PingTimeoutMs = 1000
$script:ServiceStartTimeoutSec = 15
$script:ServicePollDelaySec = 1
$script:DefaultCommandPollMs = 1000
$script:FallbackWatchdogIntervalMs = 10000
# Tray command channel is untrusted input (tray runs unprivileged): only these
# verbs exist, compared case-sensitively against the raw JSON value.
$script:CommandVerbWhitelist = @('switch', 'retest', 'setoption', 'shutdown')
# setoption payload bounds: only these engine config keys are writable and each
# accepts exactly the validated value set from Config.psm1 (same enforcement).
$script:OptionValueWhitelist = @{
    'gameFilterMode' = @('disabled', 'all', 'tcp', 'udp')
    'ipsetMode'      = @('loaded', 'none', 'any')
}
# Strategy names are zapret-core strategy file names, so they are filesystem
# bounded; the cap bounds comparisons and log lines before any lookup.
$script:MaxStrategyNameLength = 260
# Untrusted fields echoed into log lines are truncated to keep logs reviewable.
$script:MaxCommandFieldLogLength = 64
$script:MaxOptionNameLength = 32
$script:MaxOptionValueLength = 32

function Get-ScServiceState {
    # Raw sc.exe query result for any service: 'RUNNING', 'STOPPED', 'none' or 'unknown'.
    # The STATE keyword is localized on non-English Windows, but sc.exe always
    # prints the English state enum names, so match those instead of the keyword.
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $output = & sc.exe query $Name 2>&1
        $text = ($output | Out-String)
        if ($text -match '\b(RUNNING|STOPPED|STOP_PENDING|START_PENDING|CONTINUE_PENDING|PAUSE_PENDING|PAUSED)\b') {
            return $Matches[1]
        }
        if ($LASTEXITCODE -ne 0) {
            # 1060 = service does not exist; other non-zero exits stay 'unknown'
            # (e.g. access denied must not be mistaken for "not installed").
            if ($text -match '1060') { return 'none' }
            return 'unknown'
        }
        return 'unknown'
    } catch {
        return 'unknown'
    }
}

function Get-ManagedWinwsProcesses {
    $core = [IO.Path]::GetFullPath((Resolve-ZapretCore)).TrimEnd('\')
    $expected = [IO.Path]::GetFullPath((Join-Path $core 'bin\winws.exe'))
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue | Where-Object {
            $_.ExecutablePath -and [string]::Equals([IO.Path]::GetFullPath($_.ExecutablePath), $expected, [StringComparison]::OrdinalIgnoreCase)
        })
    } catch {
        return @()
    }
}

function Stop-ManagedWinws {
    $processes = @(Get-ManagedWinwsProcesses)
    foreach ($process in $processes) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Service' 'ManagedWinwsStopped' "count=$($processes.Count)"
    return $processes.Count
}

function Get-ZapretServiceState {
    # Compatibility name for status.json: the managed background winws process,
    # not a Windows service. 'none' means zlazy currently owns no live process.
    if (@(Get-ManagedWinwsProcesses).Count -gt 0) { return 'running' }
    return 'none'
}

function New-WinwsBinPath {
    # Builds the sc.exe binPath= value the way service.bat does:
    # quoted winws.exe path followed by args; tokens containing whitespace or
    # quotes are wrapped in quotes; every literal quote is emitted as \" because
    # sc.exe treats backslash-quote as an escaped quote inside binPath values.
    param(
        [Parameter(Mandatory = $true)][string]$WinwsPath,
        [AllowEmptyCollection()][string[]]$Arguments
    )
    $tokens = @()
    foreach ($arg in $Arguments) {
        if ($arg -match '[\s"]') {
            $tokens += '"' + $arg + '"'
        } else {
            $tokens += $arg
        }
    }
    $logical = '"' + $WinwsPath + '"'
    if ($tokens.Count -gt 0) {
        $logical += ' ' + ($tokens -join ' ')
    }
    return ($logical -replace '"', '\"')
}

function Install-ZapretService {
    # Compatibility name: launch the selected stock .bat as a managed background
    # process. No Windows service is created; the engine owns the winws lifetime.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$StrategyName,
        [AllowEmptyCollection()][string[]]$ArgumentList
    )
    try {
        if ($StrategyName -notmatch '^general[^\\/]*\.bat$' -or $StrategyName -match '\.\.') {
            Write-Log 'Service' 'ProcessStartFailed' "strategy=$StrategyName reason=invalidName"
            return $false
        }
        $core = Resolve-ZapretCore
        $batPath = Join-Path $core $StrategyName
        $winwsPath = Join-Path (Join-Path $core 'bin') $script:WinwsImageName
        if (-not (Test-Path -LiteralPath $batPath) -or -not (Test-Path -LiteralPath $winwsPath)) {
            Write-Log 'Service' 'ProcessStartFailed' "strategy=$StrategyName reason=payloadMissing"
            return $false
        }

        & net.exe stop $script:ServiceName 2>$null | Out-Null
        & sc.exe delete $script:ServiceName 2>$null | Out-Null
        [void](Stop-ManagedWinws)
        $env:NO_UPDATE_CHECK = '1'
        $cmdLine = '/d /c "' + $batPath + '"'
        Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WorkingDirectory $core -WindowStyle Hidden | Out-Null

        $deadline = (Get-Date).AddSeconds($script:ServiceStartTimeoutSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds $script:ServicePollDelaySec
            $managed = @(Get-ManagedWinwsProcesses)
            if ($managed.Count -gt 0) {
                Write-Log 'Service' 'ProcessStarted' "strategy=$StrategyName pid=$($managed[0].ProcessId) mode=bat"
                return $true
            }
        }
        Write-Log 'Service' 'ProcessStartFailed' "strategy=$StrategyName reason=timeout"
        return $false
    } catch {
        Write-Log 'Service' 'ProcessStartFailed' "strategy=$StrategyName error=$($_.Exception.Message)"
        return $false
    }
}

function Remove-ZapretService {
    # Stop only our payload's winws and remove legacy service entries. The donor
    # or another manually started winws outside zlazy-core is not terminated.
    try {
        [void](Stop-ManagedWinws)
        & net.exe stop $script:ServiceName 2>$null | Out-Null
        & sc.exe delete $script:ServiceName 2>$null | Out-Null
        if (-not (Get-Process -Name 'winws' -ErrorAction SilentlyContinue)) {
            & net.exe stop $script:WinDivertServiceName 2>$null | Out-Null
            & sc.exe delete $script:WinDivertServiceName 2>$null | Out-Null
            & net.exe stop $script:WinDivert14ServiceName 2>$null | Out-Null
            & sc.exe delete $script:WinDivert14ServiceName 2>$null | Out-Null
        }
        Write-Log 'Service' 'BackgroundRemoved' ''
        return $true
    } catch {
        Write-Log 'Service' 'RemoveFailed' "error=$($_.Exception.Message)"
        return $false
    }
}

function Measure-NetworkSample {
    # Pings each target once with a 1000 ms timeout (mirrors utils/test zapret.ps1)
    # and builds the Status.network block: up = at least one reply.
    param([AllowEmptyCollection()][string[]]$Targets)
    $samples = @()
    $up = $false
    foreach ($target in $Targets) {
        $ms = $null
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($target, $script:PingTimeoutMs)
            if ($reply -and $reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $ms = [int]$reply.RoundtripTime
                $up = $true
            }
        } catch {
            Write-Log 'Service' 'PingFailed' "target=$target error=$($_.Exception.Message)"
        } finally {
            $ping.Dispose()
        }
        $samples += [pscustomobject]@{ target = $target; ms = $ms }
    }
    if ($Targets.Count -eq 0) { $up = $true }
    return [pscustomobject]@{ up = $up; samples = $samples }
}

# ---------------------------------------------------------------------------
# VPN detection: zapret is pointless (and its tests meaningless) while the
# internet route goes through a VPN tunnel, so the engine pauses itself.
# The best IPv4 interface towards a public address is asked from the routing
# table (GetBestInterface, microseconds per call) and classified once per
# interface index (Get-NetAdapter, cached).
# ---------------------------------------------------------------------------
$script:VpnProbeAddress = '1.1.1.1'
# IANA ifType: 23 ppp, 53 propVirtual (Wintun/WireGuard), 131 tunnel.
$script:VpnInterfaceTypes = @(23, 53, 131)
$script:VpnNamePattern = 'wintun|wireguard|tap-windows|\btap\d*\b|\btun\d*\b|openvpn|vpn|xray|v2ray|sing-?box|outline|amnezia|nekoray|hiddify|happ|anyconnect|fortinet|globalprotect|pangp|nordlynx|tailscale|zerotier'
$script:VpnClassCache = @{}

function Initialize-RouteNative {
    if ($null -ne ('ZapretLazy.Native.RouteMethods' -as [type])) { return $true }
    try {
        Add-Type -Namespace ZapretLazy.Native -Name RouteMethods -MemberDefinition '[DllImport("iphlpapi.dll")] public static extern int GetBestInterface(uint dwDestAddr, out uint pdwBestIfIndex);' -ErrorAction Stop
        return $true
    } catch {
        Write-Log 'Service' 'VpnProbeUnavailable' "error=$($_.Exception.Message)"
        return $false
    }
}

function Get-VpnClassification {
    # @{ Vpn = bool; Name = string } for one interface index (cached).
    param([Parameter(Mandatory = $true)][int]$IfIndex)
    if ($script:VpnClassCache.ContainsKey($IfIndex)) { return $script:VpnClassCache[$IfIndex] }
    $result = [pscustomobject]@{ Vpn = $false; Name = '' }
    try {
        $adapter = Get-NetAdapter -InterfaceIndex $IfIndex -IncludeHidden -ErrorAction Stop | Select-Object -First 1
        $text = ([string]$adapter.InterfaceDescription + ' ' + [string]$adapter.ComponentID + ' ' + [string]$adapter.DriverProvider + ' ' + [string]$adapter.Name)
        $result.Name = [string]$adapter.Name
        $result.Vpn = ($script:VpnInterfaceTypes -contains [int]$adapter.InterfaceType) -or ($text -match $script:VpnNamePattern)
    } catch {
        # RAS/PPP connections (built-in Windows VPN) have no NetAdapter object.
        try {
            foreach ($nic in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                $ipv4 = $null
                try { $ipv4 = $nic.GetIPProperties().GetIPv4Properties() } catch { }
                if ($null -ne $ipv4 -and $ipv4.Index -eq $IfIndex) {
                    $result.Name = [string]$nic.Name
                    $type = $nic.NetworkInterfaceType
                    $result.Vpn = ($type -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Ppp) -or `
                        ($type -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Tunnel) -or `
                        (([string]$nic.Description + ' ' + [string]$nic.Name) -match $script:VpnNamePattern)
                    break
                }
            }
        } catch { }
    }
    $script:VpnClassCache[$IfIndex] = $result
    return $result
}

function Get-VpnState {
    # @{ Active = bool; Name = string }. Any probe failure reads as "no VPN" so a
    # broken probe can never pause the bypass forever.
    $state = [pscustomobject]@{ Active = $false; Name = '' }
    if (-not (Initialize-RouteNative)) { return $state }
    try {
        $bytes = [System.Net.IPAddress]::Parse($script:VpnProbeAddress).GetAddressBytes()
        $dest = [BitConverter]::ToUInt32($bytes, 0)
        [uint32]$ifIndex = 0
        if ([ZapretLazy.Native.RouteMethods]::GetBestInterface($dest, [ref]$ifIndex) -ne 0) { return $state }
        $class = Get-VpnClassification -IfIndex ([int]$ifIndex)
        $state.Active = [bool]$class.Vpn
        $state.Name = [string]$class.Name
    } catch { }
    return $state
}

function Set-StatusDefaults {
    # Adds missing schema properties to the live Status object so StrictMode-safe
    # assignments never fail, no matter which phase built the object.
    param($Status)
    if (-not $Status.PSObject.Properties['network']) {
        $Status | Add-Member -MemberType NoteProperty -Name network -Value ([pscustomobject]@{ up = $false; samples = @() })
    }
    if (-not $Status.network.PSObject.Properties['up']) {
        $Status.network | Add-Member -MemberType NoteProperty -Name up -Value $false
    }
    if (-not $Status.network.PSObject.Properties['samples']) {
        $Status.network | Add-Member -MemberType NoteProperty -Name samples -Value @()
    }
    foreach ($name in 'updatedAt', 'phase', 'activeStrategy', 'serviceState', 'lastTestAt', 'message', 'payloadVersion', 'gameFilterMode', 'ipsetMode') {
        if (-not $Status.PSObject.Properties[$name]) {
            $Status | Add-Member -MemberType NoteProperty -Name $name -Value $null
        }
    }
    if (-not $Status.PSObject.Properties['greenStrategies']) {
        $Status | Add-Member -MemberType NoteProperty -Name greenStrategies -Value @()
    }
    if (-not $Status.PSObject.Properties['vpn']) {
        $Status | Add-Member -MemberType NoteProperty -Name vpn -Value ([pscustomobject]@{ active = $false; name = $null })
    }
}

function Get-CommandFilePath {
    return (Join-Path (Join-Path (Get-Root) 'state') 'commands.json')
}

function Get-ProcessedCommandFilePath {
    return (Join-Path (Join-Path (Get-Root) 'state') 'commands.processed.json')
}

function Move-CommandToProcessed {
    # After handling, the command file is moved to commands.processed.json
    # (overwriting), per state ownership in CONVENTIONS.md.
    $source = Get-CommandFilePath
    if (-not (Test-Path -LiteralPath $source)) { return }
    try {
        Move-Item -LiteralPath $source -Destination (Get-ProcessedCommandFilePath) -Force
    } catch {
        Write-Log 'Service' 'CommandMoveFailed' "error=$($_.Exception.Message)"
    }
}

function Resolve-TrayCommand {
    # Executes one tray command. Returns 'retest' or 'options' when the monitor
    # loop must exit for Autopilot; a successfully applied option skips the full
    # strategy test. Every command is dropped after handling. The payload is
    # untrusted (the tray runs unprivileged), so commands, strategies and option
    # values are validated as raw typed values — never coerced. 'issuedAt' is
    # read for diagnostics only (see CONVENTIONS "state/commands.json").
    param(
        [Parameter(Mandatory = $true)]$Command,
        [Parameter(Mandatory = $true)]$Status,
        [Parameter(Mandatory = $true)]$StrategyMap,
        [Parameter(Mandatory = $true)]$Config,
        # Called with the strategy name after a successful manual switch so the
        # engine can remember the user's choice until the next test.
        [AllowNull()][scriptblock]$OnStrategySwitched = $null
    )

    $commandProp = $null
    if ($Command.PSObject.Properties['command']) {
        $commandProp = $Command.PSObject.Properties['command']
    }
    $name = $null
    if ($null -ne $commandProp) { $name = $commandProp.Value }

    # Non-string verbs and anything outside the exact whitelist are rejected
    # without touching strategy validation, and dropped by the caller.
    if ($name -isnot [string] -or $script:CommandVerbWhitelist -cnotcontains $name) {
        $commandType = 'missing'
        if ($null -ne $name) { $commandType = $name.GetType().Name }
        $issuedAt = ''
        $issuedProp = $null
        if ($Command.PSObject.Properties['issuedAt']) {
            $issuedProp = $Command.PSObject.Properties['issuedAt']
        }
        if ($null -ne $issuedProp -and $null -ne $issuedProp.Value) {
            $issuedAt = [string]$issuedProp.Value
            if ($issuedAt.Length -gt $script:MaxCommandFieldLogLength) {
                $issuedAt = $issuedAt.Substring(0, $script:MaxCommandFieldLogLength)
            }
        }
        Write-Log 'Service' 'CommandRejected' "commandType=$commandType reason=unknownCommand issuedAt=$issuedAt"
        return $false
    }

    if ($name -eq 'switch') {
        $strategyProp = $null
        if ($Command.PSObject.Properties['strategy']) {
            $strategyProp = $Command.PSObject.Properties['strategy']
        }
        if ($null -eq $strategyProp -or [string]::IsNullOrEmpty($strategyProp.Value)) {
            Write-Log 'Service' 'CommandSwitch' 'result=rejected reason=missingStrategy'
            return $false
        }
        if ($strategyProp.Value -isnot [string]) {
            Write-Log 'Service' 'CommandSwitch' "strategyType=$($strategyProp.Value.GetType().Name) result=rejected reason=notGreen"
            return $false
        }
        $strategy = $strategyProp.Value
        if ($strategy.Length -gt $script:MaxStrategyNameLength) {
            Write-Log 'Service' 'CommandSwitch' "strategyLength=$($strategy.Length) result=rejected reason=notGreen"
            return $false
        }
        # String-only list: a greenStrategies entry that is not a plain string
        # can never authorize a switch.
        $green = @()
        if ($Status.greenStrategies) {
            $green = @($Status.greenStrategies | Where-Object { $_ -is [string] })
        }
        if ($green -cnotcontains $strategy) {
            Write-Log 'Service' 'CommandSwitch' "strategy=$strategy result=rejected reason=notGreen"
            return $false
        }
        if (-not $StrategyMap.ContainsKey($strategy)) {
            Write-Log 'Service' 'CommandSwitch' "strategy=$strategy result=rejected reason=unknownStrategy"
            return $false
        }
        $strategyArgs = $StrategyMap[$strategy]
        if ($null -eq $strategyArgs) { $strategyArgs = @() }
        $Status.phase = 'installing'
        $Status.message = "Switching strategy - $strategy"
        if ($Status.PSObject.Properties['progress']) {
            $Status.progress.stage = 'installing'
            $Status.progress.strategy = $strategy
            $Status.progress.index = 0
            $Status.progress.total = 0
        }
        Write-Status -Status $Status
        $installed = Install-ZapretService -Config $Config -StrategyName $strategy -ArgumentList @($strategyArgs)
        if ($installed) {
            $Status.phase = 'monitoring'
            $Status.activeStrategy = $strategy
            $Status.serviceState = 'running'
            $Status.message = "Active: $strategy"
            if ($Status.PSObject.Properties['progress']) {
                $Status.progress.stage = 'done'
                $Status.progress.strategy = $null
            }
            Write-Status -Status $Status
            Write-Log 'Service' 'CommandSwitch' "strategy=$strategy result=installed"
            if ($null -ne $OnStrategySwitched) {
                try { & $OnStrategySwitched $strategy } catch {
                    Write-Log 'Service' 'SwitchRememberFailed' "strategy=$strategy error=$($_.Exception.Message)"
                }
            }
        } else {
            $Status.phase = 'error'
            $Status.message = "Switch failed: $strategy"
            if ($Status.PSObject.Properties['progress']) { $Status.progress.stage = 'error' }
            Write-Status -Status $Status
            Write-Log 'Service' 'CommandSwitch' "strategy=$strategy result=installFailed"
        }
        return $false
    }

    if ($name -eq 'shutdown') {
        Write-Log 'Service' 'CommandShutdown' ''
        return 'shutdown'
    }

    if ($name -eq 'retest') {
        Write-Log 'Service' 'CommandRetest' ''
        return 'retest'
    }

    if ($name -eq 'setoption') {
        # Widget option steppers (game filter / ipset list). Both the option
        # name and the value are validated as raw typed values against a fixed
        # whitelist (never coerced); on success the config is persisted and
        # 'options' is returned so Autopilot reapplies the current strategy
        # through Preflight without another full strategy test.
        $optionProp = $null
        if ($Command.PSObject.Properties['option']) { $optionProp = $Command.PSObject.Properties['option'] }
        $valueProp = $null
        if ($Command.PSObject.Properties['value']) { $valueProp = $Command.PSObject.Properties['value'] }
        if ($null -eq $optionProp -or $optionProp.Value -isnot [string] -or `
            $null -eq $valueProp -or $valueProp.Value -isnot [string]) {
            Write-Log 'Service' 'CommandSetOption' 'result=rejected reason=missingFields'
            return $false
        }
        $option = $optionProp.Value
        $value = $valueProp.Value
        if ($option.Length -gt $script:MaxOptionNameLength -or -not $script:OptionValueWhitelist.ContainsKey($option)) {
            Write-Log 'Service' 'CommandSetOption' "option=$option result=rejected reason=unknownOption"
            return $false
        }
        if ($value.Length -gt $script:MaxOptionValueLength -or $script:OptionValueWhitelist[$option] -cnotcontains $value) {
            Write-Log 'Service' 'CommandSetOption' "option=$option result=rejected reason=invalidValue"
            return $false
        }
        try {
            $fresh = Get-Config
            $fresh.$option = $value
            Save-Config -Config $fresh
            Write-Log 'Service' 'CommandSetOption' "option=$option value=$value result=applied"
        } catch {
            Write-Log 'Service' 'CommandSetOption' "option=$option result=failed error=$($_.Exception.Message)"
            return $false
        }
        return 'options'
    }

    # Unreachable: the whitelist check above already rejected every other verb.
    return $false
}

function Invoke-MonitorPass {
    # One watchdog cycle for the managed background process.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Status,
        [Parameter(Mandatory = $true)]$StrategyMap
    )
    Set-StatusDefaults -Status $Status

    $targets = @()
    if ($Config.monitor.pingTargets) { $targets = @($Config.monitor.pingTargets) }
    $sample = Measure-NetworkSample -Targets $targets
    $Status.network.up = $sample.up
    $Status.network.samples = $sample.samples

    $state = Get-ZapretServiceState
    $Status.serviceState = $state
    $active = [string]$Status.activeStrategy
    if ($state -eq 'none' -and $Status.phase -eq 'monitoring' -and $Status.network.up -and $StrategyMap.ContainsKey($active)) {
        Write-Log 'Service' 'WatchdogRestart' "strategy=$active mode=background"
        $arguments = @($StrategyMap[$active])
        if (-not (Install-ZapretService -Config $Config -StrategyName $active -ArgumentList $arguments)) {
            Write-Log 'Service' 'WatchdogStartFailed' "strategy=$active"
        }
        $Status.serviceState = Get-ZapretServiceState
    }

    $Status.updatedAt = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss'Z'")
    Write-Status -Status $Status
}

function Enter-MonitorLoop {
    # Infinite monitor phase. Ticks every monitor.commandPollMs for tray
    # commands; every monitor.watchdogIntervalSec runs a full watchdog pass
    # (network sample, service state, restart when needed, Write-Status).
    # Returns @{Retest=$true} when the tray requests a retest.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)]$Status,
        [Parameter(Mandatory = $true)]$StrategyMap,
        # Maintenance: return @{Maintenance=$true} every MaintenanceIntervalSec
        # of monitoring, or at once (Wake=$true) when the wall clock jumped by
        # WakeGapSec or more between two poll ticks (resume from sleep or
        # hibernation). 0 disables either check.
        [int]$MaintenanceIntervalSec = 0,
        [int]$WakeGapSec = 0,
        [AllowNull()][scriptblock]$OnStrategySwitched = $null
    )
    Write-Log 'Service' 'MonitorEnter' "strategy=$($Status.activeStrategy)"
    Set-StatusDefaults -Status $Status

    $intervalMs = [int]($Config.monitor.watchdogIntervalSec) * 1000
    $pollMs = [int]($Config.monitor.commandPollMs)
    if ($intervalMs -le 0) { $intervalMs = $script:FallbackWatchdogIntervalMs }
    if ($pollMs -le 0) { $pollMs = $script:DefaultCommandPollMs }
    if ($pollMs -gt $intervalMs) { $pollMs = $intervalMs }

    $maintenanceWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastWallClock = Get-Date
    while ($true) {
        try {
            # Wait one watchdog interval, polling tray commands every poll tick.
            $waitedMs = 0
            while ($waitedMs -lt $intervalMs) {
                Start-Sleep -Milliseconds $pollMs
                $waitedMs += $pollMs

                $wallNow = Get-Date
                $wallGapSec = ($wallNow - $lastWallClock).TotalSeconds
                $lastWallClock = $wallNow
                if ($WakeGapSec -gt 0 -and $wallGapSec -ge $WakeGapSec) {
                    Write-Log 'Service' 'MonitorExit' "reason=wake gapSec=$([int]$wallGapSec)"
                    return @{ Retest = $true; ApplyOptions = $false; Shutdown = $false; Maintenance = $true; Wake = $true }
                }
                if ($MaintenanceIntervalSec -gt 0 -and $maintenanceWatch.Elapsed.TotalSeconds -ge $MaintenanceIntervalSec) {
                    Write-Log 'Service' 'MonitorExit' 'reason=maintenance'
                    return @{ Retest = $true; ApplyOptions = $false; Shutdown = $false; Maintenance = $true; Wake = $false }
                }

                $vpn = Get-VpnState
                if ($vpn.Active) {
                    Write-Log 'Service' 'MonitorExit' "reason=vpn adapter=$($vpn.Name)"
                    return @{ Retest = $true; ApplyOptions = $false; Shutdown = $false; VpnPause = $true }
                }

                $command = Read-Command
                if ($null -eq $command) {
                    if (Test-Path -LiteralPath (Get-CommandFilePath)) {
                        # Corrupt command file: Config already logged the parse
                        # error; drop it so it is not retried forever.
                        Move-CommandToProcessed
                    }
                    continue
                }

                # A malformed command must never wedge the loop: even if command
                # validation itself throws, the file is dropped (moved to
                # processed) instead of being retried every poll tick.
                $action = $false
                try {
                    $action = Resolve-TrayCommand -Command $command -Status $Status -StrategyMap $StrategyMap -Config $Config -OnStrategySwitched $OnStrategySwitched
                } finally {
                    Move-CommandToProcessed
                }
                if ($action) {
                    Write-Status -Status $Status
                    $applyOptions = ($action -eq 'options')
                    $shutdown = ($action -eq 'shutdown')
                    Write-Log 'Service' 'MonitorExit' "reason=$action"
                    return @{ Retest = (-not $shutdown); ApplyOptions = $applyOptions; Shutdown = $shutdown }
                }
            }

            Invoke-MonitorPass -Config $Config -Status $Status -StrategyMap $StrategyMap
        } catch {
            Write-Log 'Service' 'MonitorError' "error=$($_.Exception.Message)"
        }
    }
}

Export-ModuleMember -Function Install-ZapretService, Remove-ZapretService, `
    Get-ZapretServiceState, Enter-MonitorLoop, Get-VpnState, Measure-NetworkSample, `
    Move-CommandToProcessed, Set-StatusDefaults
