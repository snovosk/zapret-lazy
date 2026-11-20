# Preflight.psm1 — pre-flight checks and payload state normalization for zapret-lazy.
# Mirrors service.bat: network wait, payload check, stray winws cleanup, conflicting
# service removal, TCP timestamps, load_user_lists, game/ipset switch state.
# See docs/CONVENTIONS.md. Exports only Invoke-Preflight.

Set-StrictMode -Version Latest

if (-not (Get-Module -Name 'Config')) {
    Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
}

# --- Named constants (no magic numbers) ---
$script:DnsProbeHost             = 'github.com'
$script:HttpProbeUrl            = 'https://raw.githubusercontent.com'
$script:HttpProbeTimeoutSec     = 8
$script:NetworkRetrySec         = 5
$script:NetworkMaxWaitSec       = 120
$script:IpsetMarkerCidr         = '203.0.113.113/32'
$script:IpsetServiceUrl         = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/refs/heads/main/.service/ipset-service.txt'
$script:IpsetDownloadTimeoutSec = 30
$script:ConflictBypassServices  = @('GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2')
$script:WinDivertServices       = @('WinDivert14', 'WinDivert')
$script:ValidGameFilterModes    = @('disabled', 'all', 'tcp', 'udp')
$script:ValidIpsetModes         = @('loaded', 'none', 'any')
# ACL hardening trustees as locale-independent well-known SIDs: the English
# names (BUILTIN\Administrators, BUILTIN\Users) fail to resolve on localized
# Windows (icacls exit 1332), the SIDs never do. The '*' prefix is icacls SID
# notation; the same trustees end up in the ACL.
$script:AclTrusteeSystem        = '*S-1-5-18'     # NT AUTHORITY\SYSTEM
$script:AclTrusteeAdministrators = '*S-1-5-32-544' # BUILTIN\Administrators
$script:AclTrusteeUsers         = '*S-1-5-32-545' # BUILTIN\Users

function Invoke-Preflight {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Config)

    Write-Log 'Preflight' 'Start' "gameFilterMode=$($Config.gameFilterMode) ipsetMode=$($Config.ipsetMode)"

    # Network readiness is ensured by the caller (Autopilot Wait-NetworkReady
    # runs right before every preflight); probing again only duplicated it.
    if (-not (Test-PayloadBinaries)) {
        Write-Log 'Preflight' 'Failed' 'step=payload-binaries'
        return $false
    }
    Stop-StrayWinws
    Remove-ConflictingServices
    Enable-TcpTimestamps
    Initialize-UserLists
    Set-GameFilterMode -Config $Config
    Set-IpsetMode -Config $Config

    $hardenAcls = $false
    if ($Config.PSObject.Properties['security'] -and $Config.security.PSObject.Properties['hardenAcls']) {
        $hardenAcls = [bool]$Config.security.hardenAcls
    }
    if ($hardenAcls) {
        try {
            Protect-EngineTree -Root (Get-Root)
            Write-Log 'Security' 'AclHardened' "root=$(Get-Root)"
        } catch {
            Write-Log 'Security' 'AclHardenFailed' "path=$(Get-Root) error=$($_.Exception.Message)"
        }
    } else {
        Write-Log 'Security' 'AclHardenSkipped' 'reason=hardenAcls-disabled'
    }

    Write-Log 'Preflight' 'Complete'
    return $true
}

function Invoke-OptionsPreflight {
    # Lightweight runtime option apply: no network wait, service scan or ACL pass.
    param([Parameter(Mandatory = $true)]$Config)
    Set-GameFilterMode -Config $Config
    Set-IpsetMode -Config $Config
    Write-Log 'Preflight' 'OptionsAppliedFast' "gameFilterMode=$($Config.gameFilterMode) ipsetMode=$($Config.ipsetMode)"
}

function Invoke-NetworkWait {
    # Loop until DNS resolves github.com AND a HEAD request to raw.githubusercontent.com
    # succeeds. Retry every NetworkRetrySec up to NetworkMaxWaitSec total; $false on timeout.
    Write-Log 'Preflight' 'NetworkWaitStart' "host=$script:DnsProbeHost url=$script:HttpProbeUrl"
    Enable-Tls12
    $deadline = (Get-Date).AddSeconds($script:NetworkMaxWaitSec)
    $attempt = 0
    while ($true) {
        $attempt++
        $dnsOk = Test-DnsProbe
        $httpOk = $false
        $httpStatus = 'skipped'
        if ($dnsOk) {
            try {
                $response = Invoke-WebRequest -Method Head -Uri $script:HttpProbeUrl -TimeoutSec $script:HttpProbeTimeoutSec -UseBasicParsing
                $httpStatus = [string][int]$response.StatusCode
                $httpOk = $true
            } catch {
                $httpStatus = 'error'
            }
        }
        if ($dnsOk -and $httpOk) {
            Write-Log 'Preflight' 'NetworkUp' "attempt=$attempt http=$httpStatus"
            return $true
        }
        if ((Get-Date) -ge $deadline) {
            Write-Log 'Preflight' 'NetworkTimeout' "attempt=$attempt dns=$dnsOk http=$httpStatus"
            return $false
        }
        Write-Log 'Preflight' 'NetworkRetry' "attempt=$attempt dns=$dnsOk http=$httpStatus"
        Start-Sleep -Seconds $script:NetworkRetrySec
    }
}

function Test-DnsProbe {
    try {
        $result = @(Resolve-DnsName -Name $script:DnsProbeHost -ErrorAction Stop)
        return ($result.Count -gt 0)
    } catch {
        return $false
    }
}

function Enable-Tls12 {
    # GitHub is TLS 1.2+; Windows PowerShell 5.1 may default to older protocols.
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    } catch {
        Write-Log 'Preflight' 'Tls12SetupFailed' "error=$($_.Exception.Message)"
    }
}

function Test-PayloadBinaries {
    $binDir = Join-Path (Resolve-ZapretCore) 'bin'
    $required = @(
        (Join-Path $binDir 'winws.exe'),
        (Join-Path $binDir 'WinDivert64.sys')
    )
    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            Write-Log 'Preflight' 'PayloadMissing' "path=$path"
            return $false
        }
    }
    Write-Log 'Preflight' 'PayloadBinariesOk' "bin=$binDir"
    return $true
}

function Stop-StrayWinws {
    $processes = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue)
    if ($processes.Count -eq 0) {
        Write-Log 'Preflight' 'StrayWinwsNone'
        return
    }
    $processes | Stop-Process -Force
    Write-Log 'Preflight' 'StrayWinwsStopped' "count=$($processes.Count)"
}

function Remove-ConflictingServices {
    # Bypass services conflict with zapret (service.bat diagnostics list).
    foreach ($name in $script:ConflictBypassServices) {
        Remove-ConflictingService -Name $name
    }
    # WinDivert drivers can only be removed while no winws process holds them.
    $winwsRunning = @(Get-Process -Name 'winws' -ErrorAction SilentlyContinue).Count -gt 0
    if ($winwsRunning) {
        Write-Log 'Preflight' 'WinDivertCleanupSkipped' 'reason=winws-running'
        return
    }
    foreach ($name in $script:WinDivertServices) {
        Remove-ConflictingService -Name $name
    }
}

function Remove-ConflictingService {
    param([Parameter(Mandatory = $true)][string]$Name)

    & sc.exe query $Name 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'Preflight' 'ConflictAbsent' "name=$Name"
        return
    }
    Write-Log 'Preflight' 'ConflictFound' "name=$Name"
    & net.exe stop $Name 2>&1 | Out-Null
    & sc.exe delete $Name 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Preflight' 'ConflictRemoved' "name=$Name"
    } else {
        Write-Log 'Preflight' 'ConflictRemoveFailed' "name=$Name exit=$LASTEXITCODE"
    }
}

function Enable-TcpTimestamps {
    $output = @(netsh interface tcp show global)
    $line = $output | Where-Object { $_ -match 'timestamps' } | Select-Object -First 1
    if ($null -ne $line -and $line -match 'enabled') {
        Write-Log 'Preflight' 'TcpTimestampsAlreadyEnabled'
        return
    }
    & netsh interface tcp set global timestamps=enabled 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Preflight' 'TcpTimestampsEnabled'
    } else {
        Write-Log 'Preflight' 'TcpTimestampsEnableFailed' "exit=$LASTEXITCODE"
    }
}

function Initialize-UserLists {
    # Mirror service.bat :load_user_lists — create user lists only when missing.
    $listsDir = Join-Path (Resolve-ZapretCore) 'lists'
    if (-not (Test-Path -LiteralPath $listsDir)) {
        New-Item -ItemType Directory -Path $listsDir | Out-Null
        Write-Log 'Preflight' 'ListsDirCreated' "path=$listsDir"
    }
    $specs = @(
        @{ Name = 'ipset-exclude-user.txt'; Content = "$script:IpsetMarkerCidr`r`n" },
        @{ Name = 'list-general-user.txt';  Content = "# Never leave this file empty`r`ndomain.example.abc`r`n" },
        @{ Name = 'list-exclude-user.txt';  Content = "domain.example.abc`r`n" }
    )
    foreach ($spec in $specs) {
        $path = Join-Path $listsDir $spec.Name
        if (Test-Path -LiteralPath $path) { continue }
        Write-Utf8File -Path $path -Content $spec.Content
        Write-Log 'Preflight' 'UserListCreated' "name=$($spec.Name)"
    }
}

function Set-GameFilterMode {
    # Mirror service.bat :game_switch — flag file in utils, word = all/tcp/udp,
    # absence = disabled.
    param([Parameter(Mandatory = $true)]$Config)

    $mode = [string]$Config.gameFilterMode
    if ($script:ValidGameFilterModes -notcontains $mode) {
        Write-Log 'Preflight' 'GameFilterInvalidMode' "mode=$mode"
        return
    }
    $utilsDir = Join-Path (Resolve-ZapretCore) 'utils'
    if (-not (Test-Path -LiteralPath $utilsDir)) {
        New-Item -ItemType Directory -Path $utilsDir | Out-Null
    }
    $flagPath = Join-Path $utilsDir 'game_filter.enabled'

    if ($mode -eq 'disabled') {
        if (Test-Path -LiteralPath $flagPath) {
            Remove-Item -LiteralPath $flagPath -Force
            Write-Log 'Preflight' 'GameFilterDisabled'
        } else {
            Write-Log 'Preflight' 'GameFilterAlreadyDisabled'
        }
        return
    }

    $current = $null
    if (Test-Path -LiteralPath $flagPath) {
        $current = Get-Content -LiteralPath $flagPath -TotalCount 1 -ErrorAction SilentlyContinue
    }
    if ($current -eq $mode) {
        Write-Log 'Preflight' 'GameFilterUnchanged' "mode=$mode"
        return
    }
    Write-Utf8File -Path $flagPath -Content "$mode`r`n"
    Write-Log 'Preflight' 'GameFilterApplied' "mode=$mode"
}

function Set-IpsetMode {
    # Mirror service.bat :ipset_switch — none = marker file (current list backed up),
    # any = empty file, loaded = restore backup or download the service list.
    param([Parameter(Mandatory = $true)]$Config)

    $mode = [string]$Config.ipsetMode
    if ($script:ValidIpsetModes -notcontains $mode) {
        Write-Log 'Preflight' 'IpsetInvalidMode' "mode=$mode"
        return
    }
    $listsDir = Join-Path (Resolve-ZapretCore) 'lists'
    if (-not (Test-Path -LiteralPath $listsDir)) {
        New-Item -ItemType Directory -Path $listsDir | Out-Null
    }
    $listPath = Join-Path $listsDir 'ipset-all.txt'
    $backupPath = "$listPath.backup"
    $state = Get-IpsetListState -ListPath $listPath

    if ($mode -eq 'none') {
        if ($state -eq 'none') {
            Write-Log 'Preflight' 'IpsetUnchanged' 'mode=none'
            return
        }
        if (Test-Path -LiteralPath $listPath) {
            if (Test-Path -LiteralPath $backupPath) { Remove-Item -LiteralPath $backupPath -Force }
            Rename-Item -LiteralPath $listPath -NewName 'ipset-all.txt.backup'
            Write-Log 'Preflight' 'IpsetBackupCreated' "path=$backupPath"
        }
        Write-Utf8File -Path $listPath -Content "$script:IpsetMarkerCidr`r`n"
        Write-Log 'Preflight' 'IpsetApplied' 'mode=none'
        return
    }

    if ($mode -eq 'any') {
        if ($state -eq 'any') {
            Write-Log 'Preflight' 'IpsetUnchanged' 'mode=any'
            return
        }
        Write-Utf8File -Path $listPath -Content ''
        Write-Log 'Preflight' 'IpsetApplied' 'mode=any'
        return
    }

    # mode = loaded
    if ($state -eq 'loaded') {
        Write-Log 'Preflight' 'IpsetUnchanged' 'mode=loaded'
        return
    }
    if (Test-Path -LiteralPath $backupPath) {
        if (Test-Path -LiteralPath $listPath) { Remove-Item -LiteralPath $listPath -Force }
        Rename-Item -LiteralPath $backupPath -NewName 'ipset-all.txt'
        Write-Log 'Preflight' 'IpsetRestoredFromBackup' "path=$backupPath"
        return
    }
    Write-Log 'Preflight' 'IpsetDownloading' "url=$script:IpsetServiceUrl"
    try {
        Enable-Tls12
        $response = Invoke-WebRequest -Uri $script:IpsetServiceUrl -TimeoutSec $script:IpsetDownloadTimeoutSec -UseBasicParsing
        if ([int]$response.StatusCode -eq 200) {
            Write-Utf8File -Path $listPath -Content $response.Content
            Write-Log 'Preflight' 'IpsetDownloaded' "bytes=$($response.RawContentLength)"
        } else {
            Write-Log 'Preflight' 'IpsetDownloadFailed' "status=$([int]$response.StatusCode)"
        }
    } catch {
        Write-Log 'Preflight' 'IpsetDownloadFailed' "error=$($_.Exception.Message)"
    }
}

function Get-IpsetListState {
    # State detection mirroring service.bat :ipset_switch_status:
    # no non-empty lines = any, marker present = none, otherwise loaded.
    param([Parameter(Mandatory = $true)][string]$ListPath)

    if (-not (Test-Path -LiteralPath $ListPath)) { return 'missing' }
    $lines = @(Get-Content -LiteralPath $ListPath -Encoding UTF8 | Where-Object { $_.Trim() -ne '' })
    if ($lines.Count -eq 0) { return 'any' }
    $markerPattern = [regex]::Escape($script:IpsetMarkerCidr)
    foreach ($line in $lines) {
        if ($line -match $markerPattern) { return 'none' }
    }
    return 'loaded'
}

function Write-Utf8File {
    # UTF-8 without BOM so winws list parsing never sees a BOM as content.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyString()][string]$Content
    )
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Get-InteractiveUserSid {
    # The tray runs unelevated in the interactive session, so its account must
    # hold FullControl of state/ and settings.json (commands.json, widget
    # geometry). The engine usually runs as SYSTEM, where the "current"
    # identity is SYSTEM itself and useless here — resolve the console user
    # from the explorer.exe process owner instead. $null when unavailable.
    try {
        $explorer = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
            Select-Object -First 1
        if ($null -ne $explorer) {
            $owner = $explorer.GetOwner()
            if ($owner.ReturnValue -eq 0 -and -not [string]::IsNullOrWhiteSpace($owner.User)) {
                $domain = $owner.Domain
                if ([string]::IsNullOrWhiteSpace($domain)) { $domain = $env:COMPUTERNAME }
                $ntAccount = New-Object System.Security.Principal.NTAccount($domain, $owner.User)
                return [System.Security.Principal.SecurityIdentifier]($ntAccount.Translate([System.Security.Principal.SecurityIdentifier]))
            }
        }
    } catch { }
    return $null
}

function Protect-EngineTree {
    # ACL model per docs/CONVENTIONS.md: drop the inherited "Authenticated
    # Users: Modify" so unprivileged accounts cannot replace files the SYSTEM
    # engine executes. Non-fatal throughout — every failure is logged and the
    # walk continues. Idempotent: /inheritance:r + /grant:r yield the same
    # explicit ACL on every run.
    param([Parameter(Mandatory = $true)][string]$Root)

    # Engine-owned code, payload, logs and reports: SYSTEM/Administrators
    # FullControl, unprivileged users ReadAndExecute only.
    $engineGrants = @(
        "${script:AclTrusteeSystem}:(OI)(CI)F",
        "${script:AclTrusteeAdministrators}:(OI)(CI)F",
        "${script:AclTrusteeUsers}:(OI)(CI)RX"
    )
    foreach ($rel in @('zapret-core\bin', 'src', 'launcher', 'tray', 'logs', 'reports')) {
        Set-PathAcl -Path (Join-Path $Root $rel) -Grants $engineGrants
    }

    # State + canonical config: the interactive tray user (unelevated, so the
    # Administrators group is deny-only in its token) must be granted
    # explicitly by SID. Fallback: BUILTIN\Users keeps the tray functional on
    # hosts without an interactive session (state is user-writable by design).
    $stateTrustees = @($script:AclTrusteeSystem, $script:AclTrusteeAdministrators)
    $interactiveSid = Get-InteractiveUserSid
    if ($null -ne $interactiveSid) {
        $stateTrustees += "*$($interactiveSid.Value)"
    } else {
        $stateTrustees += $script:AclTrusteeUsers
    }
    Set-PathAcl -Path (Join-Path $Root 'state') -Grants ($stateTrustees | ForEach-Object { "${_}:(OI)(CI)F" })
    Set-PathAcl -Path (Join-Path $Root 'settings.json') -Grants ($stateTrustees | ForEach-Object { "${_}:F" })
}

function Set-PathAcl {
    # One icacls pass: strip inherited ACEs, replace explicit grants. Any
    # failure is logged (Security AclHardenFailed) and swallowed by design.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Grants
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log 'Security' 'AclHardenFailed' "path=$Path error=path-not-found"
        return
    }
    # Boot speed: icacls walks the whole subtree (~1 s per path). The ACL is
    # idempotent, so skip the pass when the explicit ACL already matches.
    if (Test-PathAclMatches -Path $Path -Grants $Grants) { return }
    $icaclsArgs = @($Path, '/inheritance:r')
    foreach ($grant in $Grants) {
        $icaclsArgs += "/grant:r `"$grant`""
    }
    try {
        # Start-Process does not set $LASTEXITCODE; the exit code is read from
        # the waited process object instead.
        $process = Start-Process -FilePath 'icacls.exe' -ArgumentList $icaclsArgs -Wait -PassThru -WindowStyle Hidden
        $exitCode = $process.ExitCode
    } catch {
        Write-Log 'Security' 'AclHardenFailed' "path=$Path error=$($_.Exception.Message)"
        return
    }
    if ($exitCode -ne 0) {
        Write-Log 'Security' 'AclHardenFailed' "path=$Path error=icacls-exit-$exitCode"
    }
}

function Test-PathAclMatches {
    # $true when Path already carries exactly the protected explicit ACL that
    # Set-PathAcl would write: inheritance disabled, one allow rule per grant
    # with the same SID, rights and inheritance flags, and nothing else.
    # Any doubt (read error, unknown grant syntax) returns $false -> icacls runs.
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string[]]$Grants
    )
    try {
        $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
        if (-not $acl.AreAccessRulesProtected) { return $false }
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $expected = @{}
        foreach ($grant in $Grants) {
            if ($grant -notmatch '^\*(S-[\d-]+):(.*)$') { return $false }
            $sid = $Matches[1]
            $spec = $Matches[2]
            $inherit = $spec -match '\(OI\)\(CI\)'
            $rightsCode = ($spec -replace '\((OI|CI)\)', '')
            switch ($rightsCode) {
                'F'  { $rights = [System.Security.AccessControl.FileSystemRights]::FullControl }
                'RX' { $rights = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute }
                default { return $false }
            }
            $expected[$sid] = @{ Rights = $rights; Inherit = $inherit }
        }
        if ($rules.Count -ne $expected.Count) { return $false }
        $none = [System.Security.AccessControl.InheritanceFlags]::None
        foreach ($rule in $rules) {
            if ($rule.IsInherited) { return $false }
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
            $sid = $rule.IdentityReference.Value
            if (-not $expected.ContainsKey($sid)) { return $false }
            $want = $expected[$sid]
            # Compare ignoring the Synchronize bit icacls adds to RX grants.
            $sync = [int][System.Security.AccessControl.FileSystemRights]::Synchronize
            if ((([int]$rule.FileSystemRights) -bor $sync) -ne (([int]$want.Rights) -bor $sync)) { return $false }
            $hasInherit = ($rule.InheritanceFlags -ne $none)
            if ($hasInherit -ne $want.Inherit) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

Export-ModuleMember -Function Invoke-Preflight, Invoke-OptionsPreflight, Invoke-NetworkWait
