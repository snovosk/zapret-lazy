# StrategyEngine.psm1 — strategy discovery, winws argument parsing and strategy
# testing for zapret-lazy. See docs/CONVENTIONS.md.
# Mirrors behavior of zapret-core service.bat (arg parsing, game filter mapping)
# and utils/test zapret.ps1 (test methodology, runspace pool, targets).

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# Named constants (mirrors test zapret.ps1).
$script:PingTimeoutMs = 1000            # ICMP timeout for PING targets
$script:WinwsPollIntervalMs = 200       # winws process-ready poll interval
$script:WinwsSettleMs = 300             # settle delay once winws is detected
$script:ArgsWithValue = @('sni', 'host', 'altorder')   # service.bat: value joins with '='

function Get-Strategies {
    # Enumerates general*.bat strategies in zapret-core (service* excluded),
    # natural-sorted exactly like service.bat (digits padded to 8 chars).
    $core = Resolve-ZapretCore
    $files = @()
    if (Test-Path -LiteralPath $core) {
        $files = @(Get-ChildItem -LiteralPath $core -Filter 'general*.bat' -File |
            Where-Object { $_.Name -notlike 'service*' } |
            Sort-Object { [Regex]::Replace($_.Name, '(\d+)', { $args[0].Value.PadLeft(8, '0') }) })
    }
    Write-Log 'Engine' 'StrategiesFound' "count=$($files.Count)"
    return $files
}

function Get-Targets {
    # Parses zapret-core\utils\targets.txt ('Key = "https://host"' or 'Key = "PING:ip"')
    # into objects @{Name; Url; PingTarget}. Falls back to the default
    # Discord/YouTube/Google/Cloudflare set from test zapret.ps1.
    $core = Resolve-ZapretCore
    $targetsFile = Join-Path $core (Join-Path 'utils' 'targets.txt')
    $targets = New-Object System.Collections.Generic.List[object]
    if (Test-Path -LiteralPath $targetsFile) {
        Get-Content -LiteralPath $targetsFile -Encoding UTF8 | ForEach-Object {
            if ($_ -match '^\s*(\w+)\s*=\s*"(.+)"\s*$') {
                $targets.Add((New-Target -Name $matches[1] -Value $matches[2]))
            }
        }
    }
    if ($targets.Count -eq 0) {
        foreach ($entry in Get-DefaultTargetEntries) {
            $targets.Add((New-Target -Name $entry[0] -Value $entry[1]))
        }
        Write-Log 'Engine' 'TargetsDefault' "count=$($targets.Count)"
    } else {
        Write-Log 'Engine' 'TargetsLoaded' "count=$($targets.Count) source=targets.txt"
    }
    return $targets.ToArray()
}

function Get-WinwsArguments {
    # Replicates service.bat argument parsing: captures the winws.exe command text
    # (caret continuations), tokenizes (a --token starts a new argument, following
    # non--- tokens append, comma-joined), strips surrounding quotes, substitutes
    # %GameFilter%/%GameFilterTCP%/%GameFilterUDP% per Config.gameFilterMode and
    # %BIN%/%LISTS%/%~dp0, then absolutizes residual relative file paths against
    # zapret-core. Returns the argument array for winws.exe.
    param(
        [Parameter(Mandatory = $true)][string]$BatPath,
        [Parameter(Mandatory = $true)]$Config
    )
    $core = Resolve-ZapretCore
    if (-not (Test-Path -LiteralPath $BatPath)) {
        Write-Log 'Engine' 'ArgsParseFailed' "path=$BatPath reason=FileNotFound"
        return @()
    }
    $commandText = Get-WinwsCommandText -BatPath $BatPath
    if (-not $commandText) {
        Write-Log 'Engine' 'ArgsParseFailed' "path=$BatPath reason=NoWinwsLine"
        return @()
    }

    $tokens = @($commandText -split '\s+' | Where-Object { $_ -and $_ -ne '^' -and $_ -ne '^^' })

    # Group tokens into arguments (service.bat mergeargs semantics).
    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($token in $tokens) {
        if ($token.StartsWith('--')) {
            $argList.Add($token)
            continue
        }
        if ($argList.Count -eq 0) { continue }
        $prev = $argList[$argList.Count - 1]
        if ($prev -notmatch '=' -and $script:ArgsWithValue -contains $prev.TrimStart('-').ToLowerInvariant()) {
            $argList[$argList.Count - 1] = "$prev=$token"
        } else {
            $argList[$argList.Count - 1] = "$prev,$token"
        }
    }

    # Placeholder substitution per Config.gameFilterMode (CONVENTIONS mapping,
    # mirrors service.bat game_switch_status).
    $gf = Get-GameFilterValues -Mode (Get-GameFilterMode $Config)
    $binDir = (Join-Path $core 'bin') + '\'
    $listsDir = (Join-Path $core 'lists') + '\'
    $coreDir = $core + '\'

    $result = New-Object System.Collections.Generic.List[string]
    foreach ($arg in $argList) {
        $clean = $arg
        if ($clean.Length -ge 2 -and $clean.StartsWith('"') -and $clean.EndsWith('"')) {
            $clean = $clean.Substring(1, $clean.Length - 2)
        }
        $clean = $clean.Replace('%GameFilterTCP%', $gf.TCP).Replace('%GameFilterUDP%', $gf.UDP).Replace('%GameFilter%', $gf.GameFilter)
        $clean = $clean.Replace('%BIN_PATH%', $binDir).Replace('%LISTS_PATH%', $listsDir)
        $clean = $clean.Replace('%BIN%', $binDir).Replace('%LISTS%', $listsDir)
        $clean = $clean.Replace('%~dp0', $coreDir)
        $clean = Resolve-WinwsFileArgument -Arg $clean -Core $core
        # Argument tokens must be BARE values (no embedded quotes): consumers
        # quote as needed — Start-Process -ArgumentList arrays quote
        # automatically, and ServiceManager's binPath builder wraps tokens
        # containing spaces. Embedded quotes here would double-wrap inside the
        # service binPath and winws would receive split arguments.
        if ($clean.IndexOf('"') -ge 0) { $clean = $clean.Replace('"', '') }
        $result.Add($clean)
    }
    return $result.ToArray()
}

function Invoke-StrategyTests {
    # Tests each strategy: stops winws, starts winws.exe with parsed arguments,
    # waits for readiness, runs per-target checks (3 curl protocols per URL
    # target, ICMP ping per PING target) through a runspace pool, then stops
    # winws and any cmd children. Pre-existing standalone winws instances are
    # restored after the run. Optional -OnStrategyStart scriptblock is fired as
    # & $cb <1-based index> <total> <strategy name> before each strategy starts
    # (tray boot progress); a throwing callback is logged (ProgressCallbackFailed)
    # and never breaks the run. Returns CONVENTIONS allResults objects sorted
    # best-first (score=ok desc, tie-break avgPingMs asc; score 0 dropped unless
    # every strategy scored 0).
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][array]$Strategies,
        [Parameter(Mandatory = $true)][array]$Targets,
        [AllowNull()][scriptblock]$OnStrategyStart = $null,
        # Optional abort probe, checked before every strategy (VPN came up):
        # $true stops the run with OperationCanceledException after winws
        # cleanup/restore in the finally block.
        [AllowNull()][scriptblock]$ShouldAbort = $null
    )
    $core = Resolve-ZapretCore
    $winwsExe = Join-Path $core 'bin\winws.exe'
    $binDir = Join-Path $core 'bin'

    $timeoutSec = Get-TestSetting -Config $Config -Name 'curlTimeoutSec' -Default 4
    $readyTimeoutMs = Get-TestSetting -Config $Config -Name 'winwsReadyTimeoutMs' -Default 5000
    $maxParallel = Get-TestSetting -Config $Config -Name 'maxParallel' -Default 16
    $restartDelayMs = Get-TestSetting -Config $Config -Name 'strategyRestartDelayMs' -Default 500

    # TCP timestamps and *-user.txt lists are owned by Preflight (Invoke-Preflight
    # always runs before the test phase in the Autopilot pipeline); they are not
    # duplicated here.

    $urlTargetCount = @($Targets | Where-Object { $_.Url }).Count
    $pingTargetCount = @($Targets | Where-Object { -not $_.Url }).Count
    Write-Log 'Engine' 'TestsStarted' "strategies=$($Strategies.Count) urlTargets=$urlTargetCount pingTargets=$pingTargetCount timeoutSec=$timeoutSec maxParallel=$maxParallel"

    $results = New-Object System.Collections.Generic.List[object]
    $missingWinws = $false
    # Snapshot pre-existing standalone winws instances: the test run stops every
    # winws process; the snapshot is restored in the finally block below
    # (mirrors the snapshot/restore behavior of test zapret.ps1).
    $snapshot = Get-WinwsSnapshot
    $progressTotal = @($Strategies).Count
    $strategyIndex = 0

    try {
        foreach ($strategy in $Strategies) {
            $strategyIndex++
            if ($null -ne $ShouldAbort -and [bool](& $ShouldAbort)) {
                Write-Log 'Engine' 'TestsAborted' "index=$strategyIndex total=$progressTotal reason=abortRequested"
                throw (New-Object System.OperationCanceledException 'zlazy-test-aborted')
            }
            $batPath = "$strategy"
            if ($strategy -is [System.IO.FileInfo]) { $batPath = $strategy.FullName }
            $name = [System.IO.Path]::GetFileName($batPath)
            $nameField = Get-LogNameField -Name $name

            # Boot progress hook: fired before the strategy starts so the tray
            # can show a live status line. A throwing callback is logged and
            # must never break the test run.
            if ($null -ne $OnStrategyStart) {
                try {
                    & $OnStrategyStart $strategyIndex $progressTotal $name
                } catch {
                    Write-Log 'Engine' 'ProgressCallbackFailed' "$nameField index=$strategyIndex error=$($_.Exception.Message)"
                }
            }

            Stop-WinwsProcesses
            Start-Sleep -Milliseconds $restartDelayMs

            if ($missingWinws -or -not (Test-Path -LiteralPath $winwsExe)) {
                $missingWinws = $true
                Write-Log 'Engine' 'StrategyStartFailed' "$nameField reason=MissingWinwsExe"
                $results.Add((New-StrategyResult -Name $name -Ok 0 -Err (3 * $urlTargetCount) -Unsup 0 -AvgPingMs $null -FullyGreen $false -Arguments @()))
                continue
            }

            $arguments = @(Get-WinwsArguments -BatPath $batPath -Config $Config)
            if ($arguments.Count -eq 0) {
                Write-Log 'Engine' 'StrategyStartFailed' "$nameField reason=NoParsedArguments"
                $results.Add((New-StrategyResult -Name $name -Ok 0 -Err (3 * $urlTargetCount) -Unsup 0 -AvgPingMs $null -FullyGreen $false -Arguments @()))
                continue
            }

            Write-Log 'Engine' 'StrategyStart' "$nameField args=$($arguments.Count) mode=bat"
            $env:NO_UPDATE_CHECK = '1'
            $cmdLine = '/d /c "' + $batPath + '"'
            Start-Process -FilePath 'cmd.exe' -ArgumentList $cmdLine -WorkingDirectory $core -WindowStyle Hidden | Out-Null
            if (-not (Wait-WinwsReady -Process $null -TimeoutMs $readyTimeoutMs)) {
                Write-Log 'Engine' 'StrategyStartFailed' "$nameField reason=WinwsNotReady"
                Stop-WinwsProcesses
                $results.Add((New-StrategyResult -Name $name -Ok 0 -Err (3 * $urlTargetCount) -Unsup 0 -AvgPingMs $null -FullyGreen $false -Arguments $arguments))
                continue
            }
            $process = Get-Process -Name 'winws' -ErrorAction SilentlyContinue | Select-Object -First 1

            # Diagnostics: a second live winws (e.g. a restarting SCM service)
            # splits WinDivert flows and depresses every probe to ~half OK.
            $liveWinws = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
            if ($liveWinws.Count -ne 1) {
                $liveIds = @($liveWinws | ForEach-Object { $_.Id }) -join ','
                Write-Log 'Engine' 'UnexpectedWinwsCount' "$nameField count=$($liveWinws.Count) pids=$liveIds"
            }

            $targetResults = @(Invoke-TargetRunspaceTests -Targets $Targets -TimeoutSec $timeoutSec -MaxParallel $maxParallel)

            # Per-target tokens: the precise input for comparing a lazy run
            # against stock utils/test zapret.ps1 on a blocked network.
            foreach ($tr in $targetResults) {
                if ($tr.IsUrl) {
                    Write-Log 'Engine' 'TargetResult' "$nameField target=$($tr.Name) tokens=$(@($tr.Tokens) -join ',') codes=$(@($tr.Codes) -join ',')"
                }
            }
            if ($process.HasExited) {
                Write-Log 'Engine' 'WinwsExitedEarly' "$nameField exitCode=$($process.ExitCode)"
            }

            $ok = 0
            $err = 0
            $unsup = 0
            $pingSum = 0.0
            $pingCount = 0
            $allUrlOk = $true
            foreach ($tr in $targetResults) {
                if ($tr.IsUrl) {
                    $tokens = @($tr.Tokens)
                    if ($tokens.Count -ne 3) { $allUrlOk = $false }
                    foreach ($tok in $tokens) {
                        if ($tok -eq 'OK') { $ok++ }
                        elseif ($tok -eq 'UNSUP') { $unsup++; $allUrlOk = $false }
                        else { $err++; $allUrlOk = $false }
                    }
                }
                if ($null -ne $tr.PingMs) { $pingSum += [double]$tr.PingMs; $pingCount++ }
            }
            $avgPing = $null
            if ($pingCount -gt 0) { $avgPing = [math]::Round($pingSum / $pingCount, 1) }
            $fullyGreen = ($urlTargetCount -gt 0) -and $allUrlOk

            $results.Add((New-StrategyResult -Name $name -Ok $ok -Err $err -Unsup $unsup -AvgPingMs $avgPing -FullyGreen $fullyGreen -Arguments $arguments))
            Write-Log 'Engine' 'StrategyTested' "$nameField ok=$ok err=$err unsup=$unsup avgPingMs=$avgPing fullyGreen=$fullyGreen"
        }
    } finally {
        Stop-WinwsProcesses
        Restore-WinwsSnapshot -Snapshot $snapshot
    }

    $sorted = @(Get-RankedStrategyResults -Results $results.ToArray())

    $best = 'none'
    if ($sorted.Count -gt 0) { $best = $sorted[0].strategy }
    Write-Log 'Engine' 'TestsCompleted' "strategies=$($sorted.Count) green=$(@($sorted | Where-Object { $_.fullyGreen }).Count) best=$best"
    return $sorted
}

function Get-RankedStrategyResults {
    # Best-first order shared by a full run and a quick-boot merge: score=ok
    # desc, tie-break avgPingMs asc, then name; score 0 dropped unless every
    # strategy scored 0.
    param([AllowEmptyCollection()][array]$Results)
    $all = @($Results)
    $positive = @($all | Where-Object { $_.ok -gt 0 })
    $filtered = $all
    if ($positive.Count -gt 0) { $filtered = $positive }
    return @($filtered | Sort-Object `
        @{ Expression = { $_.ok }; Descending = $true }, `
        @{ Expression = { if ($null -eq $_.avgPingMs) { [double]::MaxValue } else { [double]$_.avgPingMs } } }, `
        @{ Expression = { $_.strategy } })
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

function Get-WinwsCommandText {
    # Returns the winws.exe command line from a strategy bat: everything after
    # the winws.exe token plus caret-continued lines. $null when not found.
    param([Parameter(Mandatory = $true)][string]$BatPath)
    $lines = Get-Content -LiteralPath $BatPath -Encoding UTF8
    $triggered = $false
    $text = ''
    foreach ($raw in $lines) {
        $line = $raw.TrimEnd()
        if (-not $triggered) {
            if ($line -match '^\s*(::|rem\b)') { continue }
            $idx = $line.IndexOf('winws.exe', [StringComparison]::OrdinalIgnoreCase)
            if ($idx -lt 0) { continue }
            $rest = $line.Substring($idx + 'winws.exe'.Length)
            if ($rest.StartsWith('"')) { $rest = $rest.Substring(1) }
            $triggered = $true
        } else {
            if ($line.Trim() -eq '') { continue }
            $rest = $line
        }
        $continues = $rest -match '\^\s*$'
        if ($continues) { $rest = ($rest -replace '\^\s*$', '') }
        $text = $text + ' ' + $rest
        if (-not $continues) { break }
    }
    if (-not $triggered) { return $null }
    return $text.Trim()
}

function Get-GameFilterMode {
    param($Config)
    $mode = 'disabled'
    if ($Config -and $Config.PSObject.Properties['gameFilterMode'] -and $Config.gameFilterMode) {
        $mode = "$($Config.gameFilterMode)"
    }
    return $mode
}

function Get-GameFilterValues {
    # CONVENTIONS settings.json mapping, mirrors service.bat game_switch_status.
    param([string]$Mode)
    switch ($Mode) {
        'all' { return @{ GameFilter = '1024-65535'; TCP = '1024-65535'; UDP = '1024-65535' } }
        'tcp' { return @{ GameFilter = '1024-65535'; TCP = '1024-65535'; UDP = '12' } }
        'udp' { return @{ GameFilter = '1024-65535'; TCP = '12'; UDP = '1024-65535' } }
        default { return @{ GameFilter = '12'; TCP = '12'; UDP = '12' } }
    }
}

function Resolve-WinwsFileArgument {
    # Absolutizes relative .txt/.bin file arguments (--hostlist*/--ipset*/
    # --dpi-desync-*-pattern values or @-prefixed tokens) against zapret-core.
    param(
        [Parameter(Mandatory = $true)][string]$Arg,
        [Parameter(Mandatory = $true)][string]$Core
    )
    $name = ''
    $value = ''
    $atPrefix = $false
    if ($Arg -match '^(?<n>--hostlist\S*|--ipset\S*|--dpi-desync-\S*-pattern)=(?<v>.+)$') {
        $name = $Matches['n']
        $value = $Matches['v']
    } elseif ($Arg -match '^@(?<v>.+)$') {
        $atPrefix = $true
        $value = $Matches['v']
    } else {
        return $Arg
    }
    $unquoted = ($value -replace '"', '')
    $valueAtPrefix = $false
    if (-not $atPrefix -and $unquoted.StartsWith('@')) {
        $valueAtPrefix = $true
        $unquoted = $unquoted.Substring(1)
    }
    # Composite merged values (comma-joined) are left untouched.
    if ($unquoted.Contains(',')) { return $Arg }
    if ($unquoted -notmatch '\.(txt|bin)$') { return $Arg }
    if ([System.IO.Path]::IsPathRooted($unquoted)) { return $Arg }
    $absolute = Join-Path $Core $unquoted
    if ($atPrefix) { return '@' + $absolute }
    if ($valueAtPrefix) { $absolute = '@' + $absolute }
    if ($value.StartsWith('"')) { $absolute = '"' + $absolute + '"' }
    return "$name=$absolute"
}

function Get-TestSetting {
    param(
        $Config,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Default
    )
    $value = $Default
    try {
        if ($Config -and $Config.PSObject.Properties['test'] -and $Config.test.PSObject.Properties[$Name]) {
            $parsed = [int]$Config.test.$Name
            if ($parsed -gt 0) { $value = $parsed }
        }
    } catch { }
    return $value
}

function New-Target {
    # Mirrors Convert-Target from test zapret.ps1.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Value
    )
    if ($Value -like 'PING:*') {
        $url = $null
        $pingTarget = $Value -replace '^PING:\s*', ''
    } else {
        $url = $Value
        $pingTarget = $Value -replace '^https?://', '' -replace '/.*$', ''
    }
    return [pscustomobject]@{ Name = $Name; Url = $url; PingTarget = $pingTarget }
}

function Get-DefaultTargetEntries {
    # Fallback set from test zapret.ps1 (Discord/YouTube/Google/Cloudflare + PING).
    return @(
        @('Discord Main', 'https://discord.com'),
        @('Discord Gateway', 'https://gateway.discord.gg'),
        @('Discord CDN', 'https://cdn.discordapp.com'),
        @('Discord Updates', 'https://updates.discord.com'),
        @('YouTube Web', 'https://www.youtube.com'),
        @('YouTube Short', 'https://youtu.be'),
        @('YouTube Image', 'https://i.ytimg.com'),
        @('YouTube Video Redirect', 'https://redirector.googlevideo.com'),
        @('Google Main', 'https://www.google.com'),
        @('Google Gstatic', 'https://www.gstatic.com'),
        @('Cloudflare Web', 'https://www.cloudflare.com'),
        @('Cloudflare CDN', 'https://cdnjs.cloudflare.com'),
        @('Cloudflare DNS 1.1.1.1', 'PING:1.1.1.1'),
        @('Cloudflare DNS 1.0.0.1', 'PING:1.0.0.1'),
        @('Google DNS 8.8.8.8', 'PING:8.8.8.8'),
        @('Google DNS 8.8.4.4', 'PING:8.8.4.4'),
        @('Quad9 DNS 9.9.9.9', 'PING:9.9.9.9')
    )
}

function Stop-WinwsProcesses {
    # Stops winws.exe processes and any cmd children spawned under them.
    # Logs even when count=0: a zero right after a probe phase means winws
    # exited by itself, which is diagnostic gold on blocked networks.
    $winws = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    if ($winws.Count -eq 0) {
        Write-Log 'Engine' 'WinwsStopped' 'count=0'
        return
    }
    $winwsIds = @{}
    foreach ($p in $winws) { $winwsIds[$p.Id] = $true }
    foreach ($p in $winws) {
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    $cmdChildren = @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -and $winwsIds.ContainsKey([int]$_.ParentProcessId) })
    foreach ($c in $cmdChildren) {
        Stop-Process -Id $c.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Write-Log 'Engine' 'WinwsStopped' "count=$($winws.Count)"
}

function Get-WinwsSnapshot {
    # Captures running winws.exe instances (for restore after the test run).
    try {
        return @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue |
            Select-Object ProcessId, CommandLine, ExecutablePath)
    } catch {
        return @()
    }
}

function Restore-WinwsSnapshot {
    # Restores winws.exe instances captured by Get-WinwsSnapshot; instances with
    # an identical command line that are already running are skipped.
    param([array]$Snapshot)
    if (-not $Snapshot -or $Snapshot.Count -eq 0) { return }
    $current = @()
    try {
        $current = @(Get-CimInstance Win32_Process -Filter "Name='winws.exe'" -ErrorAction SilentlyContinue |
            ForEach-Object { $_.CommandLine })
    } catch { }
    $restored = 0
    foreach ($p in $Snapshot) {
        if (-not $p.ExecutablePath) { continue }
        if ($current -contains $p.CommandLine) { continue }
        $exe = $p.ExecutablePath
        $restArgs = ''
        if ($p.CommandLine) {
            $quotedExe = '"' + $exe + '"'
            if ($p.CommandLine.StartsWith($quotedExe)) {
                $restArgs = $p.CommandLine.Substring($quotedExe.Length).Trim()
            } elseif ($p.CommandLine.StartsWith($exe)) {
                $restArgs = $p.CommandLine.Substring($exe.Length).Trim()
            }
        }
        try {
            Start-Process -FilePath $exe -ArgumentList $restArgs -WorkingDirectory (Split-Path $exe -Parent) -WindowStyle Minimized | Out-Null
            $restored++
        } catch { }
    }
    if ($restored -gt 0) { Write-Log 'Engine' 'WinwsRestored' "count=$restored" }
}

function Wait-WinwsReady {
    # Polls for winws like the stock test. Process may be null for .bat launches,
    # whose cmd launcher exits immediately after start returns.
    param(
        [AllowNull()]$Process,
        [Parameter(Mandatory = $true)][int]$TimeoutMs
    )
    $watch = [System.Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMs) {
        if ($null -ne $Process -and $Process.HasExited) { return $false }
        if (Get-Process -Name 'winws' -ErrorAction SilentlyContinue) {
            Start-Sleep -Milliseconds $script:WinwsSettleMs
            return $true
        }
        Start-Sleep -Milliseconds $script:WinwsPollIntervalMs
    }
    return $false
}

function Invoke-TargetRunspaceTests {
    # Runs per-target checks in a runspace pool (Config.test.maxParallel), waits
    # up to (timeout*3+5)s per runspace, then stops stragglers.
    param(
        [Parameter(Mandatory = $true)][array]$Targets,
        [Parameter(Mandatory = $true)][int]$TimeoutSec,
        [Parameter(Mandatory = $true)][int]$MaxParallel
    )

    $scriptBlock = {
        param($t, $timeoutSec, $pingTimeoutMs)
        $tokens = New-Object System.Collections.Generic.List[string]
        $codes = New-Object System.Collections.Generic.List[string]
        if ($t.Url) {
            $suites = @(
                @{ Label = 'HTTP';   Args = @('--http1.1') },
                @{ Label = 'TLS1.2'; Args = @('--tlsv1.2', '--tls-max', '1.2') },
                @{ Label = 'TLS1.3'; Args = @('--tlsv1.3', '--tls-max', '1.3') }
            )
            $baseArgs = @('-I', '-s', '-m', $timeoutSec, '--connect-timeout', [Math]::Min(2, $timeoutSec), '-o', 'NUL', '-w', '%{http_code}', '--show-error')
            foreach ($suite in $suites) {
                $stdout = New-Object System.Collections.Generic.List[string]
                $stderrText = ''
                $exitCode = -1
                # One retry for transient drops (exit 28 timeouts on lossy
                # networks): a suite only verdicts ERR when BOTH attempts fail.
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    $stdout = New-Object System.Collections.Generic.List[string]
                    $stderrText = ''
                    $exitCode = -1
                    try {
                        $output = & curl.exe @baseArgs @($suite.Args) $t.Url 2>&1
                        foreach ($piece in $output) {
                            if ($piece -is [System.Management.Automation.ErrorRecord]) {
                                $stderrText += $piece.Exception.Message + ' '
                            } else {
                                $stdout.Add("$piece")
                            }
                        }
                        $exitCode = $LASTEXITCODE
                    } catch {
                        $exitCode = -1
                        $stderrText = "$_"
                    }
                    if ($exitCode -eq 0) { break }
                }
                $httpCode = ($stdout -join '').Trim()
                $codes.Add($httpCode)
                if ($stderrText -match 'Could not resolve host|certificate|SSL certificate problem|self[- ]?signed|certificate verify failed|unable to get local issuer certificate') {
                    $tokens.Add('ERR')
                } elseif (($exitCode -eq 35) -or ($stderrText -match "does not support|not supported|protocol\s+'?.+?'?\s+not\s+supported|unsupported protocol|TLS.*not supported|Unrecognized option|Unknown option|unsupported option|unsupported feature|schannel")) {
                    $tokens.Add('UNSUP')
                } elseif ($exitCode -eq 0) {
                    # Stock counts a completed HTTP/TLS exchange as reachable;
                    # HEAD legitimately returns 403/404 on several targets.
                    $tokens.Add('OK')
                } else {
                    $tokens.Add('ERR')
                }
            }
        }
        $pingMs = $null
        if ($t.PingTarget) {
            try {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $reply = $ping.Send($t.PingTarget, $pingTimeoutMs)
                if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                    $pingMs = [int64]$reply.RoundtripTime
                }
                $ping.Dispose()
            } catch { }
        }
        return [pscustomobject]@{ Name = $t.Name; Tokens = $tokens.ToArray(); Codes = $codes.ToArray(); PingMs = $pingMs; IsUrl = [bool]$t.Url }
    }

    $pool = [runspacefactory]::CreateRunspacePool(1, $MaxParallel)
    $pool.Open()

    $runspaces = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) {
        $ps = [powershell]::Create().AddScript($scriptBlock)
        [void]$ps.AddArgument($target)
        [void]$ps.AddArgument($TimeoutSec)
        [void]$ps.AddArgument($script:PingTimeoutMs)
        $ps.RunspacePool = $pool
        $runspaces.Add([pscustomobject]@{
            Powershell = $ps
            Handle     = $ps.BeginInvoke()
            Name       = $target.Name
            IsUrl      = [bool]$target.Url
        })
    }

    $waitMs = (($TimeoutSec * 3) + 5) * 1000
    $byName = @{}
    foreach ($rs in $runspaces) {
        try {
            if ($rs.Handle -and $rs.Handle.AsyncWaitHandle) {
                if (-not $rs.Handle.AsyncWaitHandle.WaitOne($waitMs)) {
                    try { $rs.Powershell.Stop() } catch { }
                }
            }
        } catch { }
        $res = $null
        try {
            $outputs = @($rs.Powershell.EndInvoke($rs.Handle))
            if ($outputs.Count -gt 0) { $res = $outputs[0] }
        } catch { }
        if (-not $res) {
            $tokens = @()
            if ($rs.IsUrl) { $tokens = @('ERR', 'ERR', 'ERR') }
            $res = [pscustomobject]@{ Name = $rs.Name; Tokens = $tokens; Codes = @(); PingMs = $null; IsUrl = $rs.IsUrl }
        }
        $byName[$res.Name] = $res
        $rs.Powershell.Dispose()
    }
    $pool.Close()
    $pool.Dispose()

    $ordered = New-Object System.Collections.Generic.List[object]
    foreach ($target in $Targets) {
        if ($byName.ContainsKey($target.Name)) { $ordered.Add($byName[$target.Name]) }
    }
    return $ordered.ToArray()
}

function New-StrategyResult {
    # CONVENTIONS allResults schema entry plus the parsed winws Arguments array.
    # Note: PS 5.1 cannot hide a NoteProperty from ConvertTo-Json; integrators
    # must exclude 'Arguments' (e.g. Select-Object schema fields) before Write-Status.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][int]$Ok,
        [Parameter(Mandatory = $true)][int]$Err,
        [Parameter(Mandatory = $true)][int]$Unsup,
        $AvgPingMs,
        [Parameter(Mandatory = $true)][bool]$FullyGreen,
        [AllowEmptyCollection()][string[]]$Arguments
    )
    $obj = [pscustomobject]@{
        strategy   = $Name
        ok         = $Ok
        err        = $Err
        unsup      = $Unsup
        avgPingMs  = $AvgPingMs
        fullyGreen = $FullyGreen
    }
    $obj | Add-Member -MemberType NoteProperty -Name Arguments -Value $Arguments
    return $obj
}

function Get-LogNameField {
    # key=value log field, quoted when the value contains spaces.
    param([Parameter(Mandatory = $true)][string]$Name)
    if ($Name -match '\s') { return "name=`"$Name`"" }
    return "name=$Name"
}

function Measure-Baseline {
    # Measures target reachability WITHOUT any bypass running. If every URL
    # target is fully green in the baseline, no strategy can be "more
    # comfortable" than not intercepting traffic at all — the engine then
    # skips strategy testing and removes an existing bypass install so an
    # invasive strategy cannot degrade a working network.
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][array]$Targets
    )
    $timeoutSec = Get-TestSetting -Config $Config -Name 'curlTimeoutSec' -Default 4
    $maxParallel = Get-TestSetting -Config $Config -Name 'maxParallel' -Default 16

    Stop-WinwsProcesses
    Start-Sleep -Seconds 2

    $targetResults = @(Invoke-TargetRunspaceTests -Targets $Targets -TimeoutSec $timeoutSec -MaxParallel $maxParallel)

    $ok = 0; $err = 0; $unsup = 0; $pingSum = 0.0; $pingCount = 0
    $urlTargets = 0; $urlGreen = 0
    foreach ($t in $Targets) {
        if ($t.Url) { $urlTargets++ }
    }
    foreach ($tr in $targetResults) {
        if ($null -eq $tr) { continue }
        if ($tr.IsUrl) {
            $tokens = @($tr.Tokens)
            $allOk = ($tokens.Count -eq 3)
            foreach ($tok in $tokens) {
                if ($tok -eq 'OK') { $ok++ }
                elseif ($tok -eq 'UNSUP') { $unsup++; $allOk = $false }
                else { $err++; $allOk = $false }
            }
            if ($allOk) { $urlGreen++ }
        }
        if ($null -ne $tr.PingMs) { $pingSum += [double]$tr.PingMs; $pingCount++ }
    }
    $avgPing = $null
    if ($pingCount -gt 0) { $avgPing = [math]::Round($pingSum / $pingCount, 1) }
    $fullyGreen = ($urlTargets -gt 0 -and $urlGreen -eq $urlTargets)
    Write-Log 'Engine' 'BaselineMeasured' "ok=$ok err=$err unsup=$unsup fullyGreen=$fullyGreen"
    return New-StrategyResult -Name '(baseline: no bypass)' -Ok $ok -Err $err -Unsup $unsup -AvgPingMs $avgPing -FullyGreen $fullyGreen -Arguments $null
}

Export-ModuleMember -Function Get-Strategies, Get-Targets, Get-WinwsArguments, Invoke-StrategyTests, Measure-Baseline, Get-RankedStrategyResults
