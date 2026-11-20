# Config.psm1 — canonical state owner and shared helpers for zapret-lazy.
# Single writer of settings.json; log marker owner. See docs/CONVENTIONS.md.

Set-StrictMode -Version Latest

$script:Root = $null

function Get-Root {
    # Project root = two levels up from this module (src/ under project root).
    if (-not $script:Root) {
        $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    }
    return $script:Root
}

function Get-ConfigPath {
    return (Join-Path (Get-Root) 'settings.json')
}

function Get-DefaultConfig {
    return [pscustomobject]@{
        schemaVersion = 1
        gameFilterMode = 'all'
        ipsetMode = 'loaded'
        updateCheck = $true
        # Strategy-test schedule (CONVENTIONS): onboot | every3days | weekly | monthly.
        testSchedule = 'onboot'
        test = [pscustomobject]@{
            curlTimeoutSec = 6
            winwsReadyTimeoutMs = 5000
            maxParallel = 16
            strategyRestartDelayMs = 500
        }
        monitor = [pscustomobject]@{
            watchdogIntervalSec = 10
            commandPollMs = 1000
            pingTargets = @('1.1.1.1', '8.8.8.8')
        }
        widget = [pscustomobject]@{
            x = $null
            y = $null
            visible = $true
            # Per-boot auto-hide after the check finishes (see CONVENTIONS).
            autoHideAfterBoot = $true
            autoHideDelaySec = 300
            pinned = $false
        }
        security = [pscustomobject]@{
            # Optional SHA256 pin for zapret-core\bin\winws.exe. Empty = pin
            # not enforced (hash is still recorded in the report/log).
            pinSha256 = ''
            # Tighten ACLs on engine-owned subtrees during Preflight.
            hardenAcls = $true
        }
    }
}

function Protect-ConfigValue {
    param([AllowNull()][string]$Value, [string[]]$Allowed, [string]$Fallback, [string]$Name)
    if ($Allowed -contains $Value) { return $Value }
    Write-Log 'Config' 'InvalidEnumClamped' "name=$Name value='$Value' fallback=$Fallback"
    return $Fallback
}

function Get-Config {
    # Loads settings.json, creating it with defaults when missing or partial.
    $path = Get-ConfigPath
    $defaults = Get-DefaultConfig
    if (-not (Test-Path $path)) {
        Save-Config $defaults
        return $defaults
    }
    try {
        $raw = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Log 'Config' 'ConfigInvalid' "path=$path error=$($_.Exception.Message)"
        return $defaults
    }
    if ($null -eq $raw -or -not ($raw -is [pscustomobject])) {
        # Whitespace-only file parses to $null; treat like corrupt config.
        Write-Log 'Config' 'ConfigInvalid' "path=$path reason=empty-or-scalar"
        return $defaults
    }
    # Shallow-merge missing sections over defaults (canonical survives round-trip).
    foreach ($section in 'test', 'monitor', 'widget') {
        if (-not $raw.PSObject.Properties[$section]) {
            $raw | Add-Member -MemberType NoteProperty -Name $section -Value $defaults.$section
        }
    }
    foreach ($prop in $defaults.PSObject.Properties.Name) {
        if (-not $raw.PSObject.Properties[$prop]) {
            $raw | Add-Member -MemberType NoteProperty -Name $prop -Value $defaults.$prop
        }
    }
    if (-not $raw.security.PSObject.Properties['pinSha256']) {
        $raw.security | Add-Member -MemberType NoteProperty -Name 'pinSha256' -Value ''
    }
    if (-not $raw.security.PSObject.Properties['hardenAcls']) {
        $raw.security | Add-Member -MemberType NoteProperty -Name 'hardenAcls' -Value $true
    }
    # A widget section written before the auto-hide feature lacks the new
    # properties: merge them in without discarding existing x/y/visible.
    if (-not $raw.widget.PSObject.Properties['autoHideAfterBoot']) {
        $raw.widget | Add-Member -MemberType NoteProperty -Name 'autoHideAfterBoot' -Value $true
    }
    if (-not $raw.widget.PSObject.Properties['autoHideDelaySec']) {
        $raw.widget | Add-Member -MemberType NoteProperty -Name 'autoHideDelaySec' -Value 300
    }
    if (-not $raw.widget.PSObject.Properties['pinned']) {
        $raw.widget | Add-Member -MemberType NoteProperty -Name 'pinned' -Value $false
    }
    # Coerce/clamp the auto-hide prefs so a hand-edited file cannot derail the tray.
    if ($raw.widget.autoHideAfterBoot -isnot [bool]) {
        Write-Log 'Config' 'InvalidEnumClamped' "name=widget.autoHideAfterBoot value='$($raw.widget.autoHideAfterBoot)' fallback=`$true"
        $raw.widget.autoHideAfterBoot = $true
    }
    if ($raw.widget.pinned -isnot [bool]) {
        Write-Log 'Config' 'InvalidEnumClamped' "name=widget.pinned value='$($raw.widget.pinned)' fallback=`$false"
        $raw.widget.pinned = $false
    }
    $delayRaw = $raw.widget.autoHideDelaySec
    if ($null -eq $delayRaw) {
        Write-Log 'Config' 'InvalidEnumClamped' 'name=widget.autoHideDelaySec value=$null fallback=300'
        $raw.widget.autoHideDelaySec = 300
    } else {
        try {
            $delayNum = [int]$delayRaw
            if ($delayNum -lt 0 -or $delayNum -gt 3600) {
                $clamped = [Math]::Max(0, [Math]::Min(3600, $delayNum))
                Write-Log 'Config' 'InvalidEnumClamped' "name=widget.autoHideDelaySec value=$delayNum fallback=$clamped"
                $delayNum = $clamped
            }
            $raw.widget.autoHideDelaySec = $delayNum
        } catch {
            Write-Log 'Config' 'InvalidEnumClamped' "name=widget.autoHideDelaySec value='$delayRaw' fallback=300"
            $raw.widget.autoHideDelaySec = 300
        }
    }
    # Clamp enum-like values so a hand-edited config cannot derail the engine.
    $raw.gameFilterMode = Protect-ConfigValue $raw.gameFilterMode @('disabled','all','tcp','udp') 'all' 'gameFilterMode'
    $raw.ipsetMode = Protect-ConfigValue $raw.ipsetMode @('loaded','none','any') 'loaded' 'ipsetMode'
    # Clamp the strategy-test schedule to its whitelist (CONVENTIONS). A
    # non-string value (null from JSON, number, object) also falls back.
    if ($raw.testSchedule -isnot [string]) {
        $typeName = 'null'
        if ($null -ne $raw.testSchedule) { $typeName = $raw.testSchedule.GetType().Name }
        Write-Log 'Config' 'InvalidEnumClamped' "name=testSchedule valueType=$typeName fallback=onboot"
        $raw.testSchedule = 'onboot'
    } else {
        $raw.testSchedule = Protect-ConfigValue $raw.testSchedule @('onboot','every3days','weekly','monthly') 'onboot' 'testSchedule'
    }
    return $raw
}

function Save-Config {
    param([Parameter(Mandatory = $true)]$Config)
    $path = Get-ConfigPath
    $tmp = "$path.tmp"
    ($Config | ConvertTo-Json -Depth 8) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $path
    Write-Log 'Config' 'Saved' "path=$path"
}

function Resolve-ZapretCore {
    # Absolute path to the managed payload directory (zapret-core).
    return (Join-Path (Get-Root) 'zapret-core')
}

function Get-StateDir {
    $dir = Join-Path (Get-Root) 'state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return $dir
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Module,
        [Parameter(Mandatory = $true)][string]$Event,
        [string]$Data = ''
    )
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[ZAP-AUTO] $stamp $Module $Event $Data".TrimEnd()
    $logDir = Join-Path (Get-Root) 'logs'
    $file = Join-Path $logDir ('autopilot-' + (Get-Date -Format 'yyyyMMdd') + '.log')
    try {
        if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
        Add-Content -Path $file -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch {
        # Tray runs unprivileged; after ACL hardening 'logs' is admin-only.
        # NOT VERIFIED here: fallback path verified in sandbox only.
        try {
            $fallback = Join-Path (Get-StateDir) 'tray.log'
            Add-Content -Path $fallback -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch {
            # Logging must never crash the caller; drop the line silently.
        }
    }
}

function Read-Status {
    # Tray/engine read path for state/status.json; $null when absent/corrupt.
    $path = Join-Path (Get-StateDir) 'status.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Log 'Config' 'StatusCorrupt' "path=$path"
        return $null
    }
}

function Write-Status {
    param([Parameter(Mandatory = $true)]$Status)
    $dir = Get-StateDir
    $path = Join-Path $dir 'status.json'
    $tmp = "$path.tmp"
    ($Status | ConvertTo-Json -Depth 10) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Force $tmp $path
}

function Read-Command {
    # Engine-side read of state/commands.json; $null when absent, corrupt or oversized.
    $path = Join-Path (Get-StateDir) 'commands.json'
    if (-not (Test-Path $path)) { return $null }
    try {
        $item = Get-Item $path
        if ($item.Length -gt 64KB) {
            Write-Log 'Config' 'CommandOversize' "path=$path length=$($item.Length)"
            return $null
        }
        return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        Write-Log 'Config' 'CommandCorrupt' "path=$path"
        return $null
    }
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Export-ModuleMember -Function Get-Root, Get-Config, Save-Config, Resolve-ZapretCore, `
    Write-Log, Read-Status, Write-Status, Read-Command, Test-IsAdmin
