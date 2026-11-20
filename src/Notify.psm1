# Notify.psm1 - tray balloon notifications and human-readable test reports.
# Exports: Send-TrayNotification, Write-Report. See docs/CONVENTIONS.md.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# Named constants (no magic numbers).
$script:BalloonDisplayMs  = 10000  # how long the shell should display the balloon
$script:BalloonLifetimeMs = 10000  # message-loop lifetime after balloon show/close
$script:MaxTrayTextLength = 63     # NotifyIcon.Text hard limit (chars)
$script:AssembliesLoaded  = $false

function Import-NotifyAssemblies {
    if ($script:AssembliesLoaded) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $script:AssembliesLoaded = $true
    } catch {
        Write-Log 'Notify' 'AssemblyLoadFailed' "error=$($_.Exception.Message)"
        throw
    }
}

function Get-ObjectProperty {
    # Strict-mode-safe property reader; returns $Default when the property is missing or $null.
    param(
        $Object,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    if ($null -eq $prop.Value) { return $Default }
    return $prop.Value
}

function Get-PingSortKey {
    # Lower avgPingMs wins; a missing ping is the worst possible value (CONVENTIONS scoring tie-break).
    param($AvgPingMs)
    if ($null -eq $AvgPingMs) { return [double]::MaxValue }
    try { return [double]$AvgPingMs } catch { return [double]::MaxValue }
}

function Send-TrayNotification {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][ValidateSet('Info', 'Warning', 'Error')][string]$Icon
    )
    # Interactive processes only: shows a tray balloon from a short-lived
    # NotifyIcon and pumps its events for at most ~10s. The headless SYSTEM
    # engine never calls this; its status is picked up by the interactive tray.
    try {
        Import-NotifyAssemblies
    } catch {
        return $false
    }

    $notifyIcon = $null
    $exitTimer = $null
    try {
        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $toolTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
        switch ($Icon) {
            'Warning' {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Warning
                $toolTipIcon = [System.Windows.Forms.ToolTipIcon]::Warning
            }
            'Error' {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Error
                $toolTipIcon = [System.Windows.Forms.ToolTipIcon]::Error
            }
            default {
                $notifyIcon.Icon = [System.Drawing.SystemIcons]::Information
                $toolTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
            }
        }
        $trayText = $Title
        if ($trayText.Length -gt $script:MaxTrayTextLength) { $trayText = $trayText.Substring(0, $script:MaxTrayTextLength) }
        $notifyIcon.Text = $trayText
        $notifyIcon.BalloonTipTitle = $Title
        $notifyIcon.BalloonTipText = $Message
        $notifyIcon.BalloonTipIcon = $toolTipIcon

        $exitTimer = New-Object System.Windows.Forms.Timer
        $exitTimer.Interval = $script:BalloonLifetimeMs
        $exitTimer.add_Tick({
            # 10s after the balloon was shown/closed: tear down and end the loop.
            try { $exitTimer.Stop() } catch {}
            try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {}
            [System.Windows.Forms.Application]::ExitThread()
        })

        # Arm the 10s window when the shell acknowledges the balloon. The timer is
        # also started before Run() as a fallback: in a headless SYSTEM session no
        # balloon events ever fire, and the loop must still exit within ~10s.
        $armExitTimer = {
            try { $exitTimer.Stop(); $exitTimer.Start() } catch {}
        }
        $notifyIcon.add_BalloonTipShown($armExitTimer)
        $notifyIcon.add_BalloonTipClosed($armExitTimer)

        Write-Log 'Notify' 'Balloon' "title=$Title icon=$Icon"
        $notifyIcon.Visible = $true
        $notifyIcon.ShowBalloonTip($script:BalloonDisplayMs)
        $exitTimer.Start()
        [System.Windows.Forms.Application]::Run()
        return $true
    } catch {
        Write-Log 'Notify' 'BalloonFailed' "title=$Title error=$($_.Exception.Message)"
        return $false
    } finally {
        if ($null -ne $exitTimer) { try { $exitTimer.Stop(); $exitTimer.Dispose() } catch {} }
        if ($null -ne $notifyIcon) { try { $notifyIcon.Visible = $false; $notifyIcon.Dispose() } catch {} }
    }
}

function Write-Report {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()]$Results,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$ChosenStrategy,
        [Parameter(Mandatory = $true)]$Config
    )
    # Writes reports/report-<yyyyMMdd-HHmmss>.txt with the per-strategy analytics
    # table (mirrors utils/test zapret.ps1) and reports/latest.json mirroring the
    # status allResults/greenStrategies content for humans. Returns the report path.
    $reportsDir = Join-Path (Get-Root) 'reports'
    if (-not (Test-Path $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir | Out-Null }

    # Normalize rows so the table and JSON are stable whatever shape the engine emitted.
    $rows = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Results) {
        $strategy = Get-ObjectProperty $item 'strategy'
        if ([string]::IsNullOrWhiteSpace([string]$strategy)) { $strategy = '(unnamed)' }
        $ok = 0
        $err = 0
        $unsup = 0
        try { $ok = [int](Get-ObjectProperty $item 'ok' 0) } catch { $ok = 0 }
        try { $err = [int](Get-ObjectProperty $item 'err' 0) } catch { $err = 0 }
        try { $unsup = [int](Get-ObjectProperty $item 'unsup' 0) } catch { $unsup = 0 }
        $avgPingMs = Get-ObjectProperty $item 'avgPingMs' $null
        if ($null -ne $avgPingMs) { try { $avgPingMs = [double]$avgPingMs } catch { $avgPingMs = $null } }
        $fullyGreen = Get-ObjectProperty $item 'fullyGreen' $null
        $rows.Add([pscustomobject]@{
            strategy   = [string]$strategy
            ok         = $ok
            err        = $err
            unsup      = $unsup
            avgPingMs  = $avgPingMs
            fullyGreen = $fullyGreen
            best       = $false
        })
    }

    # Best strategy: highest OK count, tie-break = lower avgPingMs (CONVENTIONS scoring).
    # Strategies with score 0 are excluded unless nothing scored above 0.
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) { if ($row.ok -gt 0) { $candidates.Add($row) } }
    if ($candidates.Count -eq 0) { $candidates = $rows }
    $best = $null
    foreach ($cand in $candidates) {
        if ($null -eq $best) { $best = $cand; continue }
        if ($cand.ok -gt $best.ok) { $best = $cand; continue }
        if ($cand.ok -eq $best.ok -and (Get-PingSortKey $cand.avgPingMs) -lt (Get-PingSortKey $best.avgPingMs)) { $best = $cand }
    }
    if ($null -ne $best) { $best.best = $true }
    if ($null -eq $best) { $bestName = '(none)' } else { $bestName = $best.strategy }

    # greenStrategies mirror: fully green first, in score order (best first).
    $greenFilter = New-Object System.Collections.Generic.List[object]
    foreach ($row in $rows) { if ($row.fullyGreen -eq $true) { $greenFilter.Add($row) } }
    # NOTE: no @() around the Sort-Object pipeline - PS 5.1 raises a DLR
    # ArgumentException on @(<empty pipeline>) inside a module under StrictMode.
    $greenSorted = $greenFilter | Sort-Object `
        -Property @{ Expression = { $_.ok }; Descending = $true }, `
                   @{ Expression = { Get-PingSortKey $_.avgPingMs } }
    $greenNames = New-Object System.Collections.Generic.List[string]
    foreach ($g in $greenSorted) { $greenNames.Add([string]$g.strategy) }

    try {
        $lines = New-Object System.Collections.Generic.List[string]
        $lines.Add('zapret-lazy - strategy test report')
        $lines.Add(("Generated: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')))
        $lines.Add("Chosen strategy: $ChosenStrategy")
        $testSection = Get-ObjectProperty $Config 'test' $null
        $curlTimeout = Get-ObjectProperty $testSection 'curlTimeoutSec' 'n/a'
        $maxParallel = Get-ObjectProperty $testSection 'maxParallel' 'n/a'
        $gameFilter = Get-ObjectProperty $Config 'gameFilterMode' 'n/a'
        $ipsetMode = Get-ObjectProperty $Config 'ipsetMode' 'n/a'
        $lines.Add(("Context: gameFilter={0} ipset={1} curlTimeoutSec={2} maxParallel={3}" -f $gameFilter, $ipsetMode, $curlTimeout, $maxParallel))
        $lines.Add('')
        $lines.Add('=== ANALYTICS ===')

        if ($rows.Count -eq 0) {
            $lines.Add('(no results)')
        } else {
            $maxLen = 8
            foreach ($row in $rows) { if ($row.strategy.Length -gt $maxLen) { $maxLen = $row.strategy.Length } }
            foreach ($row in $rows) {
                if ($null -eq $row.avgPingMs) { $pingText = 'n/a' } else { $pingText = $row.avgPingMs.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) }
                if ($null -eq $row.fullyGreen) { $greenText = 'n/a' }
                elseif ($row.fullyGreen) { $greenText = 'yes' }
                else { $greenText = 'no' }
                if ($row.best) { $mark = ' *' } else { $mark = '' }
                $lines.Add(("{0} : OK: {1,3}, ERR: {2,3}, UNSUP: {3,3}, avgPingMs: {4,7}, Green: {5}{6}" -f `
                    $row.strategy.PadRight($maxLen), $row.ok, $row.err, $row.unsup, $pingText, $greenText, $mark))
            }
            $lines.Add('')
            $lines.Add('(* = best strategy)')
        }
        $lines.Add('')
        $lines.Add("Best strategy: $bestName")

        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportPath = Join-Path $reportsDir ("report-$stamp.txt")
        $lines | Set-Content -Path $reportPath -Encoding UTF8

        $jsonResults = New-Object System.Collections.Generic.List[object]
        foreach ($row in $rows) {
            $jsonResults.Add([pscustomobject]@{
                strategy   = $row.strategy
                ok         = $row.ok
                err        = $row.err
                unsup      = $row.unsup
                avgPingMs  = $row.avgPingMs
                fullyGreen = $row.fullyGreen
                best       = $row.best
            })
        }
        $latest = [pscustomobject]@{
            generatedAt     = (Get-Date).ToUniversalTime().ToString('o')
            chosenStrategy  = $ChosenStrategy
            bestStrategy    = $bestName
            greenStrategies = $greenNames
            allResults      = $jsonResults
        }
        $latestPath = Join-Path $reportsDir 'latest.json'
        $tmp = "$latestPath.tmp"
        ($latest | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Force $tmp $latestPath

        Write-Log 'Notify' 'ReportWritten' "path=$reportPath latest=$latestPath best=$bestName"
        return $reportPath
    } catch {
        Write-Log 'Notify' 'ReportFailed' "error=$($_.Exception.Message)"
        throw
    }
}

Export-ModuleMember -Function Send-TrayNotification, Write-Report
