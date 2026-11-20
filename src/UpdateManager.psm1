# UpdateManager.psm1 — manages the zapret-core payload: first-run provisioning and
# self-updates from Flowseal/zapret-discord-youtube GitHub releases.
# Log marker owner for Update* events. See docs/CONVENTIONS.md.

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')

# GitHub endpoints and network budgets.
$script:VersionUrl = 'https://raw.githubusercontent.com/Flowseal/zapret-discord-youtube/main/.service/version.txt'
$script:ReleaseDownloadBaseUrl = 'https://github.com/Flowseal/zapret-discord-youtube/releases/download'
$script:VersionTimeoutSec = 10
$script:DownloadTimeoutSec = 120

# Windows service that may lock payload files during a swap.
$script:ServiceName = 'zapret'
$script:ServiceStopTimeoutSec = 15

# Staging directories live next to zapret-core so the final swap is same-volume.
$script:StagingPrefix = '.zapret-update-'

$ProgressPreference = 'SilentlyContinue'

# GitHub requires TLS 1.2; PS 5.1 does not enable it by default everywhere.
# Forced again before every web call so a downgrade can never ride a fresh runspace.
function Enable-Tls12 {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}
Enable-Tls12

function Invoke-Update {
    # Returns $true when the zapret-core payload was (re)placed and the pipeline
    # should rerun; $false when nothing changed or the update failed gracefully.
    param([Parameter(Mandatory = $true)]$Config)

    $updateEnabled = Resolve-UpdateEnabled $Config
    if (-not $updateEnabled) {
        Write-Log 'Update' 'UpdateSkipped' 'reason=disabled'
        return $false
    }

    Clear-StaleStaging

    $corePath = Resolve-ZapretCore
    $firstRun = -not (Test-Path -LiteralPath $corePath)

    try {
        $remoteVersion = Get-RemoteVersion
    } catch {
        Write-Log 'Update' 'UpdateFailed' "stage=versionCheck error=$($_.Exception.Message)"
        return $false
    }

    $localVersion = $null
    if (-not $firstRun) {
        $localVersion = Get-LocalVersion $corePath
        if ((Compare-Version $remoteVersion $localVersion) -le 0) {
            Write-Log 'Update' 'UpdateSkipped' "reason=upToDate local=$localVersion remote=$remoteVersion"
            return $false
        }
        Write-Log 'Update' 'UpdateAvailable' "local=$localVersion remote=$remoteVersion"
    }

    $stagingDir = $null
    try {
        $assetUrl = Resolve-ReleaseAssetUrl -Version $remoteVersion
        $stagingDir = Join-Path (Get-Root) ($script:StagingPrefix + (Get-Date -Format 'yyyyMMddHHmmss') + "-$PID")
        New-Item -ItemType Directory -Path $stagingDir -ErrorAction Stop | Out-Null
        Set-StagingAcl -StagingDir $stagingDir
        $archivePath = Join-Path $stagingDir 'payload.zip'
        Save-ReleaseArchive -Url $assetUrl -Destination $archivePath
        $extractDir = Join-Path $stagingDir 'extracted'
        Expand-ReleaseArchive -ArchivePath $archivePath -DestinationPath $extractDir
        $newTree = Resolve-ExtractedRoot -ExtractDir $extractDir
    } catch {
        Write-Log 'Update' 'UpdateFailed' "stage=download error=$($_.Exception.Message)"
        Remove-StagingDir $stagingDir
        return $false
    }

    # Fail-closed payload verification before the service is touched or trees swapped.
    $payloadHash = Test-PayloadIntegrity -NewTree $newTree -Config $Config
    if (-not $payloadHash) {
        Remove-StagingDir $stagingDir
        return $false
    }

    if (-not $firstRun) {
        Stop-ZapretServiceForSwap
        Copy-UserData -OldCore $corePath -NewTree $newTree
    }

    try {
        Switch-CoreTree -CorePath $corePath -NewTree $newTree -FirstRun $firstRun
    } catch {
        Write-Log 'Update' 'UpdateRollback' "error=$($_.Exception.Message)"
        Remove-StagingDir $stagingDir
        throw
    }
    Remove-StagingDir $stagingDir

    $installedVersion = Get-LocalVersion $corePath
    if ($firstRun) {
        Apply-SeedLists -CorePath $corePath
        Write-Log 'Update' 'UpdateProvisioned' "version=$installedVersion sha256=$payloadHash"
    } else {
        Write-Log 'Update' 'UpdateApplied' "old=$localVersion new=$installedVersion sha256=$payloadHash"
    }
    return $true
}

function Resolve-UpdateEnabled {
    param($Config)
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains('updateCheck')) { return [bool]$Config['updateCheck'] }
        return $true
    }
    if ($Config.PSObject.Properties['updateCheck']) {
        return [bool]$Config.updateCheck
    }
    return $true
}

function Get-RemoteVersion {
    Enable-Tls12
    $content = Invoke-RestMethod -Uri $script:VersionUrl -Headers @{ 'Cache-Control' = 'no-cache' } `
        -TimeoutSec $script:VersionTimeoutSec -UseBasicParsing -ErrorAction Stop
    $version = ([string]$content).Trim()
    if ($version -notmatch '^\d+(\.\d+)*$') {
        throw "unexpected remote version content: '$version'"
    }
    return $version
}

function Get-LocalVersion {
    param([Parameter(Mandatory = $true)][string]$CorePath)
    $versionFile = Join-Path $CorePath '.service\version.txt'
    if (Test-Path -LiteralPath $versionFile) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8).Trim()
        if ($raw -match '^\d+(\.\d+)*$') { return $raw }
        Write-Log 'Update' 'LocalVersionInvalid' "path=$versionFile content=$raw"
    }
    $serviceBat = Join-Path $CorePath 'service.bat'
    if (Test-Path -LiteralPath $serviceBat) {
        $match = [regex]::Match((Get-Content -LiteralPath $serviceBat -Raw -Encoding UTF8), 'LOCAL_VERSION=([0-9][0-9.]*)')
        if ($match.Success) { return $match.Groups[1].Value }
    }
    return '0.0.0'
}

function Compare-Version {
    # Numeric dot-part comparison: 1.10.4 > 1.9.0. Returns -1/0/1 like string.Compare.
    param(
        [Parameter(Mandatory = $true)][string]$Left,
        [Parameter(Mandatory = $true)][string]$Right
    )
    $leftParts = $Left -split '\.'
    $rightParts = $Right -split '\.'
    $count = [Math]::Max($leftParts.Count, $rightParts.Count)
    for ($i = 0; $i -lt $count; $i++) {
        $leftNum = 0
        $rightNum = 0
        if ($i -lt $leftParts.Count) { [void][int]::TryParse($leftParts[$i], [ref]$leftNum) }
        if ($i -lt $rightParts.Count) { [void][int]::TryParse($rightParts[$i], [ref]$rightNum) }
        if ($leftNum -lt $rightNum) { return -1 }
        if ($leftNum -gt $rightNum) { return 1 }
    }
    return 0
}

function Resolve-ReleaseAssetUrl {
    param([Parameter(Mandatory = $true)][string]$Version)
    if ($Version -notmatch '^\d+(\.\d+)*$') { throw 'invalid release version' }
    return "$script:ReleaseDownloadBaseUrl/$Version/zapret-discord-youtube-$Version.zip"
}

function Save-ReleaseArchive {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][string]$Destination
    )
    Enable-Tls12
    Invoke-WebRequest -Uri $Url -OutFile $Destination -TimeoutSec $script:DownloadTimeoutSec `
        -UseBasicParsing -ErrorAction Stop
}

function Resolve-ExtractedRoot {
    # Release archives extract into a single top-level folder; locate the payload
    # root by its service.bat marker to be layout-independent.
    param([Parameter(Mandatory = $true)][string]$ExtractDir)
    foreach ($dir in (Get-ChildItem -LiteralPath $ExtractDir -Directory)) {
        if (Test-Path -LiteralPath (Join-Path $dir.FullName 'service.bat')) {
            return $dir.FullName
        }
    }
    if (Test-Path -LiteralPath (Join-Path $ExtractDir 'service.bat')) {
        return $ExtractDir
    }
    throw "extracted archive has no service.bat payload root"
}

function Set-StagingAcl {
    # Staging holds the freshly downloaded, not-yet-verified payload, so only
    # SYSTEM and Administrators may touch it (docs/SECURITY.md threat 2).
    # Non-fatal by design: a failure is reported and the update continues.
    param([Parameter(Mandatory = $true)][string]$StagingDir)
    try {
        # SID literals (S-1-5-18 SYSTEM, S-1-5-32-544 Administrators): locale-proof;
        # the English group name fails to resolve on localized Windows (exit 1332).
        $arguments = '"{0}" /inheritance:r /grant:r *S-1-5-18:(OI)(CI)F *S-1-5-32-544:(OI)(CI)F' -f $StagingDir
        $process = Start-Process -FilePath 'icacls.exe' -ArgumentList $arguments -Wait -PassThru -NoNewWindow -ErrorAction Stop
        if ($process.ExitCode -eq 0) {
            Write-Log 'Security' 'StagingAclSet' "path=$StagingDir"
        } else {
            Write-Log 'Security' 'StagingAclFailed' "path=$StagingDir exitCode=$($process.ExitCode)"
        }
    } catch {
        Write-Log 'Security' 'StagingAclFailed' "path=$StagingDir error=$($_.Exception.Message)"
    }
}

function Expand-ReleaseArchive {
    # Zip-slip-safe replacement for Expand-Archive: every archive entry's
    # resolved full path must stay under the staging root or the update aborts.
    param(
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][string]$DestinationPath
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    New-Item -ItemType Directory -Path $DestinationPath -Force -ErrorAction Stop | Out-Null
    $rootFull = [IO.Path]::GetFullPath($DestinationPath)
    if (-not $rootFull.EndsWith([IO.Path]::DirectorySeparatorChar)) {
        $rootFull = $rootFull + [IO.Path]::DirectorySeparatorChar
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $zip.Entries) {
            $rel = $entry.FullName
            if ([string]::IsNullOrEmpty($rel)) { continue }
            # UNC, device, drive-qualified and alternate-data-stream tricks are
            # rejected outright before any path resolution.
            if ($rel.StartsWith('\') -or $rel.StartsWith('/') -or $rel.IndexOf(':') -ge 0) {
                Write-Log 'Security' 'ZipEntryRejected' "entry=$rel reason=unsafePath"
                throw "zip entry has unsafe path: $rel"
            }
            $target = [IO.Path]::GetFullPath((Join-Path $rootFull $rel))
            if (-not $target.StartsWith($rootFull, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Log 'Security' 'ZipEntryRejected' "entry=$rel resolved=$target"
                throw "zip entry escapes staging root: $rel"
            }
            if ($rel.EndsWith('/')) {
                New-Item -ItemType Directory -Path $target -Force -ErrorAction Stop | Out-Null
                continue
            }
            $parent = [IO.Path]::GetDirectoryName($target)
            if (-not (Test-Path -LiteralPath $parent)) {
                New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally {
        $zip.Dispose()
    }
}

function Test-PayloadIntegrity {
    # Fail-closed payload verification (docs/CONVENTIONS.md "Payload verification"):
    # the kernel driver must carry a Valid Authenticode signature and, when
    # security.pinSha256 is set, winws.exe must match the pin case-insensitively.
    # The measured SHA256 of winws.exe is always logged and reported.
    # Returns the lowercase SHA256 of winws.exe on success, $null on rejection.
    param(
        [Parameter(Mandatory = $true)][string]$NewTree,
        [Parameter(Mandatory = $true)]$Config
    )
    $sysPath = Join-Path $NewTree 'bin\WinDivert64.sys'
    if (-not (Test-Path -LiteralPath $sysPath)) {
        Write-Log 'Security' 'PayloadRejected' "reason=driverSignature status=FileNotFound path=$sysPath"
        return $null
    }
    try {
        $signature = Get-AuthenticodeSignature -FilePath $sysPath -ErrorAction Stop
    } catch {
        Write-Log 'Security' 'PayloadRejected' "reason=driverSignature status=Error error=$($_.Exception.Message)"
        return $null
    }
    if ($signature.Status -ne 'Valid') {
        Write-Log 'Security' 'PayloadRejected' "reason=driverSignature status=$($signature.Status)"
        return $null
    }
    $winwsPath = Join-Path $NewTree 'bin\winws.exe'
    if (-not (Test-Path -LiteralPath $winwsPath)) {
        Write-Log 'Security' 'PayloadRejected' "reason=winwsMissing path=$winwsPath"
        return $null
    }
    $hash = (Get-FileHash -LiteralPath $winwsPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    Write-Log 'Security' 'PayloadHash' "sha256=$hash"
    $pin = Get-PinSha256 $Config
    if (-not [string]::IsNullOrEmpty($pin) -and -not [string]::Equals($hash, $pin, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log 'Security' 'PayloadRejected' "reason=pinMismatch expected=$pin measured=$hash"
        return $null
    }
    return $hash
}

function Get-PinSha256 {
    param($Config)
    $section = $null
    if ($Config -is [System.Collections.IDictionary]) {
        if ($Config.Contains('security')) { $section = $Config['security'] }
    } elseif ($Config.PSObject.Properties['security']) {
        $section = $Config.security
    }
    if ($null -eq $section) { return '' }
    if ($section -is [System.Collections.IDictionary]) {
        if ($section.Contains('pinSha256')) { return [string]$section['pinSha256'] }
        return ''
    }
    if ($section.PSObject.Properties['pinSha256']) { return [string]$section.pinSha256 }
    return ''
}

function Copy-UserData {
    # Carry user state across the swap. The ENTIRE lists\ directory is user
    # data (domains and ipset networks): it is seeded once (from GitHub, or
    # from a donor folder at install time) and must survive payload updates
    # byte-for-byte — updates never refresh lists. Mirrors the ownership
    # rule in docs/CONVENTIONS.md.
    param(
        [Parameter(Mandatory = $true)][string]$OldCore,
        [Parameter(Mandatory = $true)][string]$NewTree
    )
    $oldLists = Join-Path $OldCore 'lists'
    if (Test-Path -LiteralPath $oldLists) {
        $newLists = Join-Path $NewTree 'lists'
        if (-not (Test-Path -LiteralPath $newLists)) {
            New-Item -ItemType Directory -Path $newLists -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath (Join-Path $oldLists '*') -Destination $newLists -Recurse -Force -ErrorAction Stop
        Write-Log 'Update' 'UserDataPreserved' 'dir=lists'
    }
    $oldTargets = Join-Path $OldCore 'utils\targets.txt'
    if (Test-Path -LiteralPath $oldTargets) {
        $newUtils = Join-Path $NewTree 'utils'
        if (-not (Test-Path -LiteralPath $newUtils)) {
            New-Item -ItemType Directory -Path $newUtils -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $oldTargets -Destination (Join-Path $newUtils 'targets.txt') -Force -ErrorAction Stop
        Write-Log 'Update' 'UserDataPreserved' 'file=utils\targets.txt'
    }
    $gameFlag = Join-Path $OldCore 'utils\game_filter.enabled'
    if (Test-Path -LiteralPath $gameFlag) {
        $newUtils = Join-Path $NewTree 'utils'
        if (-not (Test-Path -LiteralPath $newUtils)) {
            New-Item -ItemType Directory -Path $newUtils -Force -ErrorAction Stop | Out-Null
        }
        Copy-Item -LiteralPath $gameFlag -Destination (Join-Path $newUtils 'game_filter.enabled') -Force -ErrorAction Stop
        Write-Log 'Update' 'UserDataPreserved' 'file=utils\game_filter.enabled'
    }
}

function Apply-SeedLists {
    # First-run donor overlay: the installer leaves state\seed-lists.json with
    # a donor zapret folder path; after provisioning from GitHub the donor's
    # lists\ (the user's servers and networks) replace the downloaded ones.
    # Consumed once — the marker is deleted regardless of outcome after use.
    param([Parameter(Mandatory = $true)][string]$CorePath)
    $marker = Join-Path (Get-Root) 'state\seed-lists.json'
    if (-not (Test-Path -LiteralPath $marker)) { return }
    $donorPath = $null
    try {
        $seed = Get-Content -LiteralPath $marker -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($seed -and ($seed.donorPath -is [string])) { $donorPath = $seed.donorPath }
    } catch {
        Write-Log 'Update' 'SeedInvalid' "marker=$marker"
    }
    Remove-Item -LiteralPath $marker -Force -ErrorAction SilentlyContinue
    if (-not $donorPath) { return }
    $donorLists = Join-Path $donorPath 'lists'
    if (-not (Test-Path -LiteralPath (Join-Path $donorLists 'list-general.txt'))) {
        Write-Log 'Update' 'SeedSkipped' "reason=donor-lists-missing donor=$donorPath"
        return
    }
    $targetLists = Join-Path $CorePath 'lists'
    if (-not (Test-Path -LiteralPath $targetLists)) {
        New-Item -ItemType Directory -Path $targetLists -Force -ErrorAction Stop | Out-Null
    }
    try {
        Get-ChildItem -LiteralPath $donorLists -File | ForEach-Object {
            Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $targetLists $_.Name) -Force -ErrorAction Stop
        }
        Write-Log 'Update' 'SeedApplied' "donor=$donorPath"
    } catch {
        Write-Log 'Update' 'SeedFailed' "donor=$donorPath error=$($_.Exception.Message)"
    }
}

function Stop-ZapretServiceForSwap {
    $service = Get-Service -Name $script:ServiceName -ErrorAction SilentlyContinue
    if (-not $service) { return }
    if ($service.Status -eq 'Stopped') { return }
    try {
        Stop-Service -Name $script:ServiceName -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', (New-TimeSpan -Seconds $script:ServiceStopTimeoutSec))
        Write-Log 'Update' 'ServiceStopped' "name=$script:ServiceName"
    } catch {
        # Same-volume directory rename works even with open handles, so proceed and
        # let the swap try; the stale .old cleanup may fail and is reported there.
        Write-Log 'Update' 'ServiceStopFailed' "name=$script:ServiceName error=$($_.Exception.Message)"
    }
}

function Switch-CoreTree {
    # Atomic-ish swap: old tree renamed aside, new tree moved in, old removed.
    # Any failure restores the old tree before the exception propagates.
    param(
        [Parameter(Mandatory = $true)][string]$CorePath,
        [Parameter(Mandatory = $true)][string]$NewTree,
        [Parameter(Mandatory = $true)][bool]$FirstRun
    )
    $backupPath = "$CorePath.old"
    $renamed = $false
    try {
        if (-not $FirstRun) {
            if (Test-Path -LiteralPath $backupPath) {
                Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction Stop
            }
            Rename-Item -LiteralPath $CorePath -NewName ([IO.Path]::GetFileName($backupPath)) -ErrorAction Stop
            $renamed = $true
        }
        Move-Item -LiteralPath $NewTree -Destination $CorePath -ErrorAction Stop
    } catch {
        if ($renamed -and (Test-Path -LiteralPath $CorePath)) {
            # $CorePath can only hold a partial new tree after a successful rename.
            Remove-Item -LiteralPath $CorePath -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($renamed -and (Test-Path -LiteralPath $backupPath)) {
            Rename-Item -LiteralPath $backupPath -NewName ([IO.Path]::GetFileName($CorePath)) -ErrorAction SilentlyContinue
        }
        throw
    }
    if ($renamed -and (Test-Path -LiteralPath $backupPath)) {
        try {
            Remove-Item -LiteralPath $backupPath -Recurse -Force -ErrorAction Stop
        } catch {
            # A still-running winws.exe from the old tree locks files; non-fatal.
            Write-Log 'Update' 'OldTreeKept' "path=$backupPath error=$($_.Exception.Message)"
        }
    }
}

function Clear-StaleStaging {
    Get-ChildItem -LiteralPath (Get-Root) -Directory -Filter ($script:StagingPrefix + '*') -ErrorAction SilentlyContinue |
        ForEach-Object {
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
}

function Remove-StagingDir {
    param([AllowNull()][AllowEmptyString()][string]$StagingDir)
    if ($StagingDir -and (Test-Path -LiteralPath $StagingDir)) {
        Remove-Item -LiteralPath $StagingDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Export-ModuleMember -Function Invoke-Update
