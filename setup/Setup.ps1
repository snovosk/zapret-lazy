# Setup.ps1 — single-file GUI installer for zlazy (compiled to zlazy-setup.exe
# with PS2EXE; the release package is embedded as package.zip and extracted by
# the exe host to %TEMP%\zapret-lazy-setup\ before this script runs).
#
# Usage (as zlazy-setup.exe):
#   zlazy-setup.exe             elevated GUI (install / upgrade / uninstall)
#   zlazy-setup.exe [/InstallDir=C:\zapret-lazy] [/DonorPath=D:\progs\zapret-discord-youtube-main]
#             [/Scripts] [/Uninstall] [/KeepData] [/Quiet] [/NoStart]
#
#   The engine and the tray start automatically right after install (the same
#   tasks also fire at every logon). /NoStart skips the immediate start;
#   /Start is accepted for backward compatibility and is redundant now.
#
#   /Scripts   register script-mode tasks (wscript+ps1) instead of the .exe files
#              (for hosts where Smart App Control blocks unsigned executables).
#   /Uninstall remove tasks and the zapret service; without /KeepData also the folder.
#   /DonorPath folder of an existing zapret-discord-youtube install: its lists\
#              (servers and IP networks) become the initial lists and are never
#              touched again by payload updates.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PS2EXE -noConsole renders every Write-Progress (Expand-Archive, first-use
# module loading) as a separate white window: progress is never shown.
$ProgressPreference = 'SilentlyContinue'
# The compiled exe hosts a runspace under the machine's default execution
# policy; relax it for this process only so modules can be imported.
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force

$script:SetupTag = '[ZAP-AUTO-SETUP]'
$script:PackagePath = Join-Path $env:TEMP 'zapret-lazy-setup\package.zip'
$script:ExtractDir = Join-Path $env:TEMP 'zapret-lazy-setup\extract'
$script:DefaultInstallDir = 'C:\zapret-lazy'
$script:EngineTaskName = 'ZapretLazyEngine'
$script:TrayTaskName = 'ZapretLazyTray'
$script:LogoFoxBase64 = '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'

function Write-SetupLog {
    param([string]$Event, [string]$Data = '')
    $line = ('{0} {1} {2} {3}' -f $script:SetupTag, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Event, $Data).TrimEnd()
    try {
        # The exe host normally pre-creates %TEMP%\zapret-lazy-setup\ for the
        # embedded package, but never rely on it: logging must survive even
        # when everything else has already gone wrong.
        $logDir = Split-Path (Join-Path $env:TEMP 'zapret-lazy-setup\setup.log') -Parent
        if (-not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        Add-Content -Path (Join-Path $logDir 'setup.log') -Value $line -Encoding UTF8 -ErrorAction Stop
    } catch { }
}

function ConvertFrom-SetupArgs {
    param([string[]]$RawArgs)
    $parsed = @{ installDir = $null; donorPath = $null; scripts = $false; start = $false; noStart = $false; uninstall = $false; keepData = $false; quiet = $false; desktopShortcut = $true; startMenuShortcut = $true }
    foreach ($a in $RawArgs) {
        if ($null -eq $a) { continue }
        $t = ([string]$a).Trim()
        if ($t -eq '' -or $t -ieq '-end') { continue }
        if ($t -match '^/InstallDir=(.+)$') { $parsed.installDir = $Matches[1].Trim('"') }
        elseif ($t -match '^/DonorPath=(.+)$') { $parsed.donorPath = $Matches[1].Trim('"') }
        elseif ($t -ieq '/Scripts') { $parsed.scripts = $true }
        elseif ($t -ieq '/Start') { $parsed.start = $true }
        elseif ($t -ieq '/NoStart') { $parsed.noStart = $true }
        elseif ($t -ieq '/NoDesktopShortcut') { $parsed.desktopShortcut = $false }
        elseif ($t -ieq '/NoStartMenuShortcut') { $parsed.startMenuShortcut = $false }
        elseif ($t -ieq '/Uninstall') { $parsed.uninstall = $true }
        elseif ($t -ieq '/KeepData') { $parsed.keepData = $true }
        elseif ($t -ieq '/Quiet') { $parsed.quiet = $true }
        else { Write-SetupLog 'ArgIgnored' "arg=$t" }
    }
    return $parsed
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-InstallDir {
    param([string]$Requested)
    if ($Requested) { return $Requested }
    # Already installed? Follow the registered engine task's action back to its folder.
    try {
        $task = Get-ScheduledTask -TaskName $script:EngineTaskName -ErrorAction Stop
        $exe = [string]$task.Actions[0].Execute
        if ($exe -and (Test-Path -LiteralPath $exe)) {
            $dir = Split-Path $exe -Parent
            Write-SetupLog 'InstallDirFromTask' "dir=$dir"
            return $dir
        }
    } catch { }
    return $script:DefaultInstallDir
}

function Find-DonorFolder {
    param([string]$Requested)
    if ($Requested) {
        if (Test-Path -LiteralPath (Join-Path $Requested 'bin\winws.exe')) { return $Requested }
        throw "Donor folder '$Requested' does not look like a zapret install (bin\winws.exe missing)."
    }
    $candidates = @()
    foreach ($drive in @('D:', 'C:')) {
        # Join-Path itself throws on a host without the drive (e.g. no D:),
        # so probe the drive root first and swallow any residual probe error.
        if (-not (Test-Path -LiteralPath ($drive + '\'))) { continue }
        foreach ($base in @('progs', '')) {
            try {
                $rootPath = Join-Path ($drive + '\') $base
                if (-not (Test-Path -LiteralPath $rootPath)) { continue }
                $candidates += Get-ChildItem -LiteralPath $rootPath -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like 'zapret-discord-youtube*' } |
                    ForEach-Object { $_.FullName }
            } catch { }
        }
    }
    foreach ($c in ($candidates | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $c 'bin\winws.exe')) {
            Write-SetupLog 'DonorDetected' "path=$c"
            return $c
        }
    }
    return $null
}

function Get-DonorIpsetMode {
    param([string]$Donor)
    $listFile = Join-Path $Donor 'lists\ipset-all.txt'
    if (-not (Test-Path -LiteralPath $listFile)) { return 'loaded' }
    $raw = [System.IO.File]::ReadAllText($listFile)
    if ([string]::IsNullOrWhiteSpace($raw)) { return 'any' }
    $lines = @($raw -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 1 -and $lines[0].Trim() -eq '203.0.113.113/32') { return 'none' }
    return 'loaded'
}

function Get-DonorGameFilterMode {
    param([string]$Donor)
    $flag = Join-Path $Donor 'utils\game_filter.enabled'
    if (-not (Test-Path -LiteralPath $flag)) { return 'disabled' }
    $first = (Get-Content -LiteralPath $flag -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($first -match '^(all|tcp|udp)$') { return $Matches[1] }
    return 'disabled'
}

function Copy-PackageTo {
    param([string]$InstallDir)
    if (-not (Test-Path -LiteralPath $script:PackagePath)) {
        throw ("Embedded package not found at '{0}'. The exe must be built with build\Build-Exe.ps1 (-embedFiles)." -f $script:PackagePath)
    }
    if (Test-Path -LiteralPath $script:ExtractDir) { Remove-Item -LiteralPath $script:ExtractDir -Recurse -Force }
    Expand-Archive -LiteralPath $script:PackagePath -DestinationPath $script:ExtractDir -Force

    $fresh = -not (Test-Path -LiteralPath (Join-Path $InstallDir 'settings.json'))
    $backupDir = Join-Path $env:TEMP 'zapret-lazy-setup\preserved'
    if (Test-Path -LiteralPath $backupDir) { Remove-Item -LiteralPath $backupDir -Recurse -Force }
    if (-not $fresh) {
        New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $InstallDir 'settings.json') -Destination $backupDir -Force
        if (Test-Path -LiteralPath (Join-Path $InstallDir 'state')) {
            Copy-Item -LiteralPath (Join-Path $InstallDir 'state') -Destination $backupDir -Recurse -Force
        }
    }

    if (-not (Test-Path -LiteralPath $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $script:ExtractDir -Force | ForEach-Object {
        $dest = Join-Path $InstallDir $_.Name
        if ($_.PSIsContainer) {
            if (-not (Test-Path -LiteralPath $dest)) {
                New-Item -ItemType Directory -Path $dest -Force | Out-Null
            }
            # Merge, never nest: Copy-Item of a directory onto an EXISTING
            # directory in Windows PowerShell 5.1 creates dest\name\name
            # (verified on 19041), which is how re-running setup produced
            # launcher\launcher-style artifacts. Copying the children merges.
            if ((Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1)) {
                Copy-Item -Path ($_.FullName + '\*') -Destination $dest -Recurse -Force -ErrorAction Stop
            }
        } else {
            Copy-Item -LiteralPath $_.FullName -Destination $dest -Force -ErrorAction Stop
        }
    }

    foreach ($legacyExe in @('ZapretLazyEngine.exe', 'ZapretLazyTray.exe', 'Setup.exe')) {
        $legacyPath = Join-Path $InstallDir $legacyExe
        if (Test-Path -LiteralPath $legacyPath) { Remove-Item -LiteralPath $legacyPath -Force }
    }

    if (-not $fresh) {
        Copy-Item -LiteralPath (Join-Path $backupDir 'settings.json') -Destination $InstallDir -Force
        if (Test-Path -LiteralPath (Join-Path $backupDir 'state')) {
            Copy-Item -LiteralPath (Join-Path $backupDir 'state') -Destination $InstallDir -Recurse -Force
        }
    }
    return $fresh
}

function Initialize-InstallSettings {
    param([string]$InstallDir, [string]$Donor)
    Import-Module (Join-Path $InstallDir 'src\Config.psm1') -Force
    $cfg = Get-Config  # creates the canonical defaults file on a fresh install
    if ($cfg.widget.autoHideDelaySec -eq 8) {
        $cfg.widget.autoHideDelaySec = 300
        Save-Config $cfg
        Write-SetupLog 'AutoHideDefaultMigrated' 'from=8 to=300'
    }
    if ($Donor) {
        $cfg.ipsetMode = Get-DonorIpsetMode -Donor $Donor
        $cfg.gameFilterMode = Get-DonorGameFilterMode -Donor $Donor
        Save-Config $cfg
        $stateDir = Join-Path $InstallDir 'state'
        if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
        $marker = [pscustomobject]@{ donorPath = $Donor; createdAtUtc = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
        ($marker | ConvertTo-Json -Depth 4) | Set-Content -Path (Join-Path $stateDir 'seed-lists.json') -Encoding UTF8
        Write-SetupLog 'SettingsFromDonor' "ipsetMode=$($cfg.ipsetMode) gameFilterMode=$($cfg.gameFilterMode) donor=$Donor"
    } else {
        Write-SetupLog 'SettingsDefaults' ("ipsetMode=$($cfg.ipsetMode) gameFilterMode=$($cfg.gameFilterMode)")
    }
}

function Register-LazyTasks {
    param([string]$InstallDir, [bool]$UseScripts, [bool]$DesktopShortcut = $true, [bool]$StartMenuShortcut = $true)
    $regArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallDir 'launcher\Register-LazyTasks.ps1'))
    if ($UseScripts) { $regArgs += '-UseScripts' }
    if (-not $DesktopShortcut) { $regArgs += '-NoDesktopShortcut' }
    if (-not $StartMenuShortcut) { $regArgs += '-NoStartMenuShortcut' }
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $regArgs -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ('Task registration failed with exit code ' + $p.ExitCode) }
}

function Stop-RunningComponents {
    # An upgrade must never copy over a running engine/tray: their exe files
    # stay locked while the processes live, and the old build would otherwise
    # keep running after the files are replaced. End the tasks and any strays;
    # the install restarts both at the end.
    param([string]$InstallDir)
    foreach ($task in @($script:EngineTaskName, $script:TrayTaskName)) {
        Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/End', '/TN', $task) | Out-Null
    }
    Start-Sleep -Seconds 1
    foreach ($procName in @('zlazy', 'ZapretLazyEngine', 'ZapretLazyTray')) {
        Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    }
    $lockFile = Join-Path $InstallDir 'state\engine.lock'
    if (Test-Path -LiteralPath $lockFile) {
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
    Write-SetupLog 'RunningComponentsStopped'
}

function Stop-ConflictingZapret {
    # The donor remains intact. Stop its active drivers/processes so only one
    # WinDivert consumer survives the installation and subsequent reboots.
    foreach ($svc in @('zapret', 'WinDivert', 'WinDivert14', 'GoodbyeDPI', 'discordfix_zapret', 'winws1', 'winws2')) {
        Invoke-NativeQuiet -FilePath 'net.exe' -Arguments @('stop', $svc) | Out-Null
        Invoke-NativeQuiet -FilePath 'sc.exe' -Arguments @('delete', $svc) | Out-Null
        Write-SetupLog 'ConflictingServiceRemoved' "name=$svc"
    }
    foreach ($image in @('winws.exe', 'winws1.exe', 'winws2.exe', 'goodbyedpi.exe')) {
        Invoke-NativeQuiet -FilePath 'taskkill.exe' -Arguments @('/IM', $image, '/F') | Out-Null
        Write-SetupLog 'ConflictingProcessStopped' "image=$image"
    }
}

function Start-EngineAndWait {
    # Starts both autostart tasks now (not only at the next logon): the engine
    # as SYSTEM and the tray in the installing user's session, then waits for
    # the engine's first status report.
    param([string]$InstallDir, [int]$TimeoutSec = 120)
    $runExit = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/Run', '/TN', $script:EngineTaskName)
    if ($runExit -ne 0) { Write-SetupLog 'EngineStartFailed' "exitCode=$runExit" }
    Write-SetupLog 'EngineStartRequested'
    $trayExit = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/Run', '/TN', $script:TrayTaskName)
    if ($trayExit -ne 0) { Write-SetupLog 'TrayStartFailed' "exitCode=$trayExit" } else { Write-SetupLog 'TrayStartRequested' }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $statusPath = Join-Path $InstallDir 'state\status.json'
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $status = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($status.phase) {
                    Write-SetupLog 'EngineStatus' ("phase=" + $status.phase + " message=" + $status.message)
                    return
                }
            } catch { }
        }
    }
    Write-SetupLog 'EngineStartTimeout' "waited=${TimeoutSec}s"
}

function Invoke-NativeQuiet {
    # Run a native command silently and return its exit code.
    # $ErrorActionPreference = 'Stop' turns native stderr into a thrown
    # RemoteException even when redirected (verified on PS 5.1), so it is
    # relaxed for the call and native stderr is discarded via 2>$null.
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments 2>$null | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function Uninstall-Autopilot {
    param([string]$InstallDir, [bool]$KeepData)
    $exitCode = Invoke-NativeQuiet -FilePath 'powershell.exe' -Arguments @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $InstallDir 'launcher\Register-LazyTasks.ps1'), '-Unregister')
    if ($exitCode -ne 0) { Write-SetupLog 'TaskUnregisterFailed' "exitCode=$exitCode" }
    # Stop both unified and legacy entry points without touching user data.
    foreach ($procName in @('zlazy', 'ZapretLazyEngine', 'ZapretLazyTray')) {
        Stop-Process -Name $procName -Force -ErrorAction SilentlyContinue
    }
    $lockFile = Join-Path $InstallDir 'state\engine.lock'
    if (Test-Path -LiteralPath $lockFile) {
        $lockPid = 0
        if ([int]::TryParse(((Get-Content -LiteralPath $lockFile -ErrorAction SilentlyContinue) -join '').Trim(), [ref]$lockPid)) {
            Stop-Process -Id $lockPid -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue
    }
    foreach ($svc in @('zapret', 'WinDivert', 'WinDivert14')) {
        Invoke-NativeQuiet -FilePath 'net.exe' -Arguments @('stop', $svc) | Out-Null
        Invoke-NativeQuiet -FilePath 'sc.exe' -Arguments @('delete', $svc) | Out-Null
    }
    Invoke-NativeQuiet -FilePath 'taskkill.exe' -Arguments @('/IM', 'winws.exe', '/F') | Out-Null
    Write-SetupLog 'ServiceRemoved'
    if (-not $KeepData) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $InstallDir) {
            Write-SetupLog 'FolderNotFullyRemoved' "path=$InstallDir (files in use; remove manually)"
        }
    } else {
        Write-SetupLog 'FolderKept' "path=$InstallDir"
    }
}

function Invoke-SetupInstallation {
    param($Options, [bool]$DesktopShortcut = $true, [bool]$StartMenuShortcut = $true)
    $installDir = Resolve-InstallDir -Requested $Options.installDir
    $donor = Find-DonorFolder -Requested $Options.donorPath
    Write-SetupLog 'InstallDir' $installDir
    Stop-RunningComponents -InstallDir $installDir
    Stop-ConflictingZapret
    $fresh = Copy-PackageTo -InstallDir $installDir
    Write-SetupLog ('PackageDeployed' + (& { if ($fresh) { ' fresh' } else { ' upgrade (settings/state preserved)' } }))
    Initialize-InstallSettings -InstallDir $installDir -Donor $donor
    Register-LazyTasks -InstallDir $installDir -UseScripts $Options.scripts -DesktopShortcut $DesktopShortcut -StartMenuShortcut $StartMenuShortcut
    Write-SetupLog 'TasksRegistered' ("mode=" + (& { if ($Options.scripts) { 'scripts' } else { 'exe' } }))
    if (-not $Options.noStart) { Start-EngineAndWait -InstallDir $installDir }
    Write-SetupLog 'SetupDone' "dir=$installDir donor=$donor"
    return $installDir
}

function Show-SetupDialog {
    # Installer-styled replacement for MessageBox: dark card, fox header, flat
    # accent buttons. Success and confirm: no glyph, message and buttons
    # centred. Error: the widget's red rounded square, vertically centred on the
    # first text line, before left-aligned text. Sized to its content.
    # Returns $true for OK / the confirm button, $false otherwise.
    param(
        [AllowNull()]$Owner,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('success', 'error', 'confirm')][string]$Kind = 'success',
        [string]$ConfirmText = 'OK',
        [string]$CancelText = 'Отмена'
    )
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bg = [System.Drawing.Color]::FromArgb(0x13, 0x14, 0x17)
    $headerBg = [System.Drawing.Color]::FromArgb(0x19, 0x1A, 0x1E)
    $panelBg = [System.Drawing.Color]::FromArgb(0x21, 0x22, 0x27)
    $textColor = [System.Drawing.Color]::FromArgb(0xED, 0xEF, 0xF3)
    $muted = [System.Drawing.Color]::FromArgb(0x9A, 0x9B, 0xA4)
    $accent = [System.Drawing.Color]::FromArgb(0xE8, 0x72, 0x0C)
    $glyphColor = switch ($Kind) {
        'success' { [System.Drawing.Color]::FromArgb(0x6F, 0xCF, 0x7A) }
        'error'   { [System.Drawing.Color]::FromArgb(0xD9, 0x53, 0x4F) }
        default   { $accent }
    }
    $font = New-Object System.Drawing.Font('Consolas', 9)
    $titleFont = New-Object System.Drawing.Font('Consolas', 11, [System.Drawing.FontStyle]::Bold)
    # Content-driven size: the longest message line or the title (after the
    # logo) plus margins, clamped; longer text wraps inside that width.
    $showGlyph = ($Kind -eq 'error')
    $centered = (-not $showGlyph)
    $pad = 28
    $glyphSpace = 0
    if ($showGlyph) { $glyphSpace = 18 }
    $minWidth = 280
    $maxWidth = 460
    $plain = [System.Windows.Forms.TextFormatFlags]::NoPadding
    $messageNatural = [System.Windows.Forms.TextRenderer]::MeasureText($Message, $font, (New-Object System.Drawing.Size(10000, 1000)), $plain).Width
    $titleNatural = [System.Windows.Forms.TextRenderer]::MeasureText($Title, $titleFont, (New-Object System.Drawing.Size(10000, 100)), $plain).Width
    $buttonsWidth = 104
    if ($Kind -eq 'confirm') { $buttonsWidth = 104 + 8 + 96 }
    $width = [Math]::Max([Math]::Max($messageNatural + $glyphSpace + 2 * $pad, $titleNatural + 46 + 24), $buttonsWidth + 2 * $pad)
    $width = [int][Math]::Min($maxWidth, [Math]::Max($minWidth, $width + 4))

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = ($null -eq $Owner)
    $dialog.BackColor = $bg
    $dialog.ForeColor = $textColor
    $dialog.Font = $font
    $dialog.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    if ($null -ne $Owner) {
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
        try { $dialog.Icon = $Owner.Icon } catch { }
    } else {
        $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $dialog.TopMost = $true
    }

    $header = New-Object System.Windows.Forms.Panel
    $header.SetBounds(0, 0, $width, 44)
    $header.BackColor = $headerBg
    [void]$dialog.Controls.Add($header)
    $logo = New-Object System.Windows.Forms.PictureBox
    $logo.SetBounds(14, 10, 24, 24)
    $logo.BackColor = $headerBg
    $logo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    try {
        $logoStream = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($script:LogoFoxBase64))
        $logoImage = [System.Drawing.Image]::FromStream($logoStream)
        $logo.Image = [System.Drawing.Image]$logoImage.Clone()
        $logoImage.Dispose()
        $logoStream.Dispose()
    } catch { }
    [void]$header.Controls.Add($logo)
    $titleLabel = New-Object System.Windows.Forms.Label
    $titleLabel.SetBounds(46, 12, ($width - 60), 20)
    $titleLabel.Text = $Title
    $titleLabel.Font = $titleFont
    $titleLabel.ForeColor = $textColor
    $titleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    [void]$header.Controls.Add($titleLabel)

    # Message height follows the text (word wrap inside the card width).
    $textWidth = $width - 2 * $pad - $glyphSpace
    # TextBoxControl lets long tokens (paths) break mid-word exactly like the
    # Label does, so the measured height matches what is drawn.
    $measureFlags = [System.Windows.Forms.TextFormatFlags]::WordBreak -bor [System.Windows.Forms.TextFormatFlags]::TextBoxControl
    $measured = [System.Windows.Forms.TextRenderer]::MeasureText($Message, $font, (New-Object System.Drawing.Size($textWidth, 1000)), $measureFlags)
    $textHeight = [Math]::Max(18, $measured.Height + 4)

    $glyph = New-Object System.Windows.Forms.PictureBox
    # Centre the glyph on the first text line, not on a fixed pixel row.
    $firstLine = [System.Windows.Forms.TextRenderer]::MeasureText('Ag', $font, (New-Object System.Drawing.Size(1000, 100)), $measureFlags).Height
    $glyphTop = 58 + [int][Math]::Round(($firstLine - 11) / 2)
    $glyph.SetBounds($pad, $glyphTop, 11, 11)
    $glyph.BackColor = $bg
    $glyph.Tag = @{ Kind = $Kind; Color = $glyphColor }
    $glyph.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $info = $sender.Tag
        $brush = New-Object System.Drawing.SolidBrush $info.Color
        $halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x55, $info.Color))
        try {
            $w = $sender.Width; $h = $sender.Height
            switch ($info.Kind) {
                'success' {
                    $g.FillEllipse($halo, 0, 0, ($w - 1), ($h - 1))
                    $g.FillEllipse($brush, 1.5, 1.5, ($w - 4), ($h - 4))
                }
                'error' {
                    $g.FillRectangle($halo, 0, 0, $w, $h)
                    $g.FillRectangle($brush, 1, 1, ($w - 2), ($h - 2))
                }
                default {
                    $barW = [Math]::Max(2, [int]($w * 0.27))
                    $g.FillRectangle($brush, 1, 1, $barW, ($h - 2))
                    $g.FillRectangle($brush, ($w - 1 - $barW), 1, $barW, ($h - 2))
                }
            }
        } finally { $brush.Dispose(); $halo.Dispose() }
    })
    if ($showGlyph) { [void]$dialog.Controls.Add($glyph) } else { $glyph.Dispose() }

    $messageLabel = New-Object System.Windows.Forms.Label
    $messageLabel.SetBounds(($pad + $glyphSpace), 58, $textWidth, $textHeight)
    $messageLabel.Text = $Message
    $messageLabel.ForeColor = $textColor
    if ($centered) { $messageLabel.TextAlign = [System.Drawing.ContentAlignment]::TopCenter }
    [void]$dialog.Controls.Add($messageLabel)

    $buttonTop = 58 + $textHeight + 18
    $result = @{ Value = $false }
    $okButton = New-Object System.Windows.Forms.Button
    $okButton.Text = $ConfirmText
    $okButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $okButton.FlatAppearance.BorderColor = $accent
    $okButton.BackColor = $accent
    $okButton.ForeColor = [System.Drawing.Color]::White
    if ($centered -and $Kind -eq 'confirm') {
        $pairLeft = [int](($width - (96 + 8 + 104)) / 2)
        $okButton.SetBounds(($pairLeft + 96 + 8), $buttonTop, 104, 30)
    } elseif ($centered) {
        $okButton.SetBounds([int](($width - 104) / 2), $buttonTop, 104, 30)
    } else {
        $okButton.SetBounds(($width - $pad - 104), $buttonTop, 104, 30)
    }
    $okButton.add_Click({ $result.Value = $true; $dialog.Close() }.GetNewClosure())
    [void]$dialog.Controls.Add($okButton)
    $dialog.AcceptButton = $okButton
    if ($Kind -eq 'confirm') {
        $cancel = New-Object System.Windows.Forms.Button
        $cancel.Text = $CancelText
        $cancel.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $cancel.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(0x2E, 0x2F, 0x36)
        $cancel.BackColor = $panelBg
        $cancel.ForeColor = $textColor
        $cancel.SetBounds([int](($width - (96 + 8 + 104)) / 2), $buttonTop, 96, 30)
        $cancel.add_Click({ $dialog.Close() }.GetNewClosure())
        [void]$dialog.Controls.Add($cancel)
        $dialog.CancelButton = $cancel
    } else {
        $dialog.CancelButton = $okButton
    }
    $dialog.ClientSize = New-Object System.Drawing.Size($width, ($buttonTop + 30 + 16))
    $dialog.add_Shown({ $okButton.Focus() | Out-Null }.GetNewClosure())

    try {
        if ($null -ne $Owner) { [void]$dialog.ShowDialog($Owner) } else { [void]$dialog.ShowDialog() }
    } finally {
        $dialog.Dispose()
        $font.Dispose()
        $titleFont.Dispose()
    }
    return [bool]$result.Value
}

function New-SetupCheckBox {
    param(
        [int[]]$Bounds,
        [string]$Text,
        [bool]$Checked,
        [bool]$Enabled = $true,
        [System.Drawing.Color]$TextColor,
        [System.Drawing.Color]$MutedColor,
        [System.Drawing.Color]$AccentColor,
        [System.Drawing.Color]$BackColor,
        [System.Drawing.Font]$Font
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds($Bounds[0], $Bounds[1], $Bounds[2], $Bounds[3])
    $panel.BackColor = $BackColor
    $panel.Font = $Font
    $panel.Enabled = $Enabled
    $panel | Add-Member -MemberType NoteProperty -Name Checked -Value $Checked
    $panel.add_Paint({
        param($sender, $e)
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $border = New-Object System.Drawing.Pen $MutedColor
        $e.Graphics.DrawRectangle($border, 1, 6, 11, 11)
        $border.Dispose()
        if ($sender.Checked) {
            $checkColor = $AccentColor
            if (-not $sender.Enabled) { $checkColor = $MutedColor }
            $pen = New-Object System.Drawing.Pen($checkColor, 2)
            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            $e.Graphics.DrawLines($pen, @([System.Drawing.Point]::new(3, 11), [System.Drawing.Point]::new(6, 14), [System.Drawing.Point]::new(11, 8)))
            $pen.Dispose()
        }
        $color = $TextColor
        if (-not $sender.Enabled) { $color = $MutedColor }
        $rect = New-Object System.Drawing.Rectangle(22, 0, ($sender.Width - 22), $sender.Height)
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::SingleLine
        [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $Text, $Font, $rect, $color, $flags)
    }.GetNewClosure())
    $panel.add_Click({
        if (-not $this.Enabled) { return }
        $this.Checked = -not $this.Checked
        [void]$this.Invalidate()
    })
    return $panel
}

function Start-SetupWorkerProcess {
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    foreach ($argument in $Arguments) {
        if ($argument.IndexOf('"') -ge 0) { throw 'Путь содержит недопустимый символ кавычки.' }
    }
    $argumentLine = (@($Arguments | ForEach-Object {
        if ($_ -match '\s') { '"' + $_ + '"' } else { $_ }
    }) -join ' ')
    $currentExe = [Environment]::GetCommandLineArgs()[0]
    if ([IO.Path]::GetFileNameWithoutExtension($currentExe) -match '^powershell') {
        $argumentLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, $argumentLine
    }
    return Start-Process -FilePath $currentExe -ArgumentList $argumentLine -WindowStyle Hidden -PassThru
}

function Read-SetupLogDelta {
    param([Parameter(Mandatory = $true)]$State)
    if (-not (Test-Path -LiteralPath $State.LogPath)) { return '' }
    $stream = New-Object System.IO.FileStream($State.LogPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = New-Object System.IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)
    try {
        if ($State.LogOffset -gt $stream.Length) { $State.LogOffset = 0 }
        $stream.Position = $State.LogOffset
        $text = $reader.ReadToEnd()
        $State.LogOffset = $stream.Position
        return $text
    } finally {
        $reader.Dispose()
        $stream.Dispose()
    }
}

function Get-SetupProgressMilestone {
    param([string]$Kind, [string]$Event)
    if ($Kind -eq 'uninstall') {
        $items = @{
            SetupStart = @(5, 'Подготовка к удалению…')
            ServiceRemoved = @(70, 'Задачи и компоненты удалены. Удаление файлов…')
            FolderKept = @(90, 'Данные пользователя сохранены.')
            UninstallDone = @(100, 'Удаление завершено.')
        }
    } else {
        $items = @{
            SetupStart = @(5, 'Подготовка к установке…')
            InstallDir = @(10, 'Проверка папки установки…')
            RunningComponentsStopped = @(20, 'Остановка текущих компонентов…')
            ConflictingProcessStopped = @(35, 'Проверка конфликтующих процессов…')
            PackageDeployed = @(58, 'Файлы скопированы. Сохранение настроек…')
            SettingsFromDonor = @(67, 'Применение исходных списков и настроек…')
            SettingsDefaults = @(67, 'Применение настроек…')
            TasksRegistered = @(82, 'Регистрация автозапуска…')
            EngineStartRequested = @(88, 'Запуск движка…')
            TrayStartRequested = @(91, 'Запуск виджета…')
            EngineStatus = @(96, 'Проверка первого состояния…')
            SetupDone = @(100, 'Установка завершена.')
        }
    }
    if ($items.ContainsKey($Event)) { return $items[$Event] }
    return $null
}

function Show-SetupGui {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $bg = [System.Drawing.Color]::FromArgb(0x13, 0x14, 0x17)
    $panelBg = [System.Drawing.Color]::FromArgb(0x21, 0x22, 0x27)
    $textColor = [System.Drawing.Color]::FromArgb(0xED, 0xEF, 0xF3)
    $muted = [System.Drawing.Color]::FromArgb(0x9A, 0x9B, 0xA4)
    $accent = [System.Drawing.Color]::FromArgb(0xE8, 0x72, 0x0C)
    $font = New-Object System.Drawing.Font('Consolas', 9)
    $titleFont = New-Object System.Drawing.Font('Consolas', 16, [System.Drawing.FontStyle]::Bold)

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'zlazy — установка'
    $form.ClientSize = New-Object System.Drawing.Size(560, 454)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $form.BackColor = $bg
    $form.ForeColor = $textColor
    $form.Font = $font
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.TopMost = $true
    $form.add_Shown({
        $this.BringToFront()
        $this.Activate()
        $this.TopMost = $false
    })
    $exePath = [Environment]::GetCommandLineArgs()[0]
    if (Test-Path -LiteralPath $exePath) { $form.Icon = [System.Drawing.Icon]::ExtractAssociatedIcon($exePath) }

    $header = New-Object System.Windows.Forms.Panel
    $header.SetBounds(0, 0, 560, 68)
    $header.BackColor = [System.Drawing.Color]::FromArgb(0x19, 0x1A, 0x1E)
    [void]$form.Controls.Add($header)
    $logo = New-Object System.Windows.Forms.PictureBox
    $logo.SetBounds(16, 14, 40, 40)
    $logo.BackColor = [System.Drawing.Color]::Transparent
    $logoStream = New-Object System.IO.MemoryStream(,[Convert]::FromBase64String($script:LogoFoxBase64))
    $logoImage = [System.Drawing.Image]::FromStream($logoStream)
    $logo.Image = [System.Drawing.Image]$logoImage.Clone()
    $logoImage.Dispose()
    $logoStream.Dispose()
    $logo.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    [void]$header.Controls.Add($logo)
    $title = New-Object System.Windows.Forms.Label
    $title.SetBounds(68, 12, 470, 30)
    $title.Text = 'zlazy'
    $title.Font = $titleFont
    $title.ForeColor = $textColor
    [void]$header.Controls.Add($title)
    $subtitle = New-Object System.Windows.Forms.Label
    $subtitle.SetBounds(70, 43, 470, 18)
    $subtitle.Text = 'Автономный менеджер zapret'
    $subtitle.ForeColor = $muted
    [void]$header.Controls.Add($subtitle)

    $installLabel = New-Object System.Windows.Forms.Label
    $installLabel.SetBounds(20, 88, 520, 20)
    $installLabel.Text = 'Папка установки'
    [void]$form.Controls.Add($installLabel)
    $installText = New-Object System.Windows.Forms.TextBox
    $installText.SetBounds(20, 112, 434, 24)
    $installText.Text = Resolve-InstallDir -Requested $opts.installDir
    $installText.BackColor = $panelBg
    $installText.ForeColor = $textColor
    $installText.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    [void]$form.Controls.Add($installText)

    $donorLabel = New-Object System.Windows.Forms.Label
    $donorLabel.SetBounds(20, 153, 520, 36)
    $donorLabel.Text = "Папка оригинального zapret (необязательно)`nСписки серверов и IP будут взяты оттуда один раз."
    [void]$form.Controls.Add($donorLabel)
    $donorText = New-Object System.Windows.Forms.TextBox
    $donorText.SetBounds(20, 192, 434, 24)
    $donorText.Text = [string](Find-DonorFolder -Requested $opts.donorPath)
    $donorText.BackColor = $panelBg
    $donorText.ForeColor = $textColor
    $donorText.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    [void]$form.Controls.Add($donorText)

    $browseInstall = New-Object System.Windows.Forms.Button
    $browseInstall.SetBounds(462, 111, 78, 27)
    $browseInstall.Text = 'Обзор…'
    [void]$form.Controls.Add($browseInstall)
    $browseDonor = New-Object System.Windows.Forms.Button
    $browseDonor.SetBounds(462, 191, 78, 27)
    $browseDonor.Text = 'Обзор…'
    [void]$form.Controls.Add($browseDonor)
    foreach ($button in @($browseInstall, $browseDonor)) {
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderColor = $accent
        $button.BackColor = $panelBg
        $button.ForeColor = $textColor
    }
    $browseInstall.add_Click({
        Write-SetupLog 'BrowseInstallClicked'
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите папку установки zlazy'
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $installText.Text = $dialog.SelectedPath }
        $dialog.Dispose()
    }.GetNewClosure())
    $browseDonor.add_Click({
        Write-SetupLog 'BrowseDonorClicked'
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Выберите папку оригинального zapret'
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $donorText.Text = $dialog.SelectedPath }
        $dialog.Dispose()
    }.GetNewClosure())

    $desktopCheck = New-SetupCheckBox -Bounds @(20, 238, 520, 24) -Text 'Создать ярлык на рабочем столе' -Checked $true -TextColor $textColor -MutedColor $muted -AccentColor $accent -BackColor $bg -Font $font
    [void]$form.Controls.Add($desktopCheck)
    $startMenuCheck = New-SetupCheckBox -Bounds @(20, 265, 520, 24) -Text 'Добавить zlazy в меню «Пуск»' -Checked $true -TextColor $textColor -MutedColor $muted -AccentColor $accent -BackColor $bg -Font $font
    [void]$form.Controls.Add($startMenuCheck)
    $autoStartCheck = New-SetupCheckBox -Bounds @(20, 292, 520, 24) -Text 'Запустить движок и трей сразу после установки' -Checked $true -Enabled $false -TextColor $textColor -MutedColor $muted -AccentColor $accent -BackColor $bg -Font $font
    [void]$form.Controls.Add($autoStartCheck)
    $notice = New-Object System.Windows.Forms.Label
    $notice.SetBounds(20, 324, 520, 38)
    $notice.ForeColor = $muted
    $notice.Text = 'Работающие процессы оригинального zapret будут остановлены, чтобы избежать конфликта WinDivert.'
    [void]$form.Controls.Add($notice)
    $statusLabel = New-Object System.Windows.Forms.Label
    $statusLabel.SetBounds(20, 370, 520, 20)
    $statusLabel.ForeColor = $muted
    $statusLabel.Text = 'Готово к установке.'
    [void]$form.Controls.Add($statusLabel)

    # Busy indicator before the operation text: the widget's "checking" glyph
    # (three 70-degree arcs; the leading one is light, glows and hops 120 deg
    # every 500 ms). PictureBox is double-buffered, so the blink never flickers.
    $spinState = @{ Step = 0 }
    $accentHi = [System.Drawing.Color]::FromArgb(0xFF, 0x9A, 0x3C)
    $spinner = New-Object System.Windows.Forms.PictureBox
    $spinner.SetBounds(20, 373, 13, 13)
    $spinner.BackColor = $bg
    $spinner.Visible = $false
    $spinner.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $pad = 1.5
        $size = $sender.Width - 2 * $pad - 1
        $segAngles = @(-90.0, 30.0, 150.0)
        $lead = [int]$spinState.Step % 3
        $penBase = New-Object System.Drawing.Pen($accent, 1.6)
        $penLead = New-Object System.Drawing.Pen($accentHi, 1.6)
        $penHalo = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(0x55, $accentHi), 2.6)
        try {
            foreach ($pen in @($penBase, $penLead, $penHalo)) {
                $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
            }
            for ($si = 0; $si -lt 3; $si++) {
                if ($si -eq $lead) {
                    $g.DrawArc($penHalo, $pad, $pad, $size, $size, $segAngles[$si], 70)
                    $g.DrawArc($penLead, $pad, $pad, $size, $size, $segAngles[$si], 70)
                } else {
                    $g.DrawArc($penBase, $pad, $pad, $size, $size, $segAngles[$si], 70)
                }
            }
        } finally {
            $penBase.Dispose(); $penLead.Dispose(); $penHalo.Dispose()
        }
    }.GetNewClosure())
    [void]$form.Controls.Add($spinner)
    $spinTimer = New-Object System.Windows.Forms.Timer
    $spinTimer.Interval = 500
    $spinTimer.add_Tick({
        $spinState.Step = ([int]$spinState.Step + 1) % 3
        $spinner.Invalidate()
    }.GetNewClosure())
    # Text is vertically centred in its box; the spinner is centred on the same
    # line and the text starts right after it. Positions are derived from the
    # live (already DPI-scaled) bounds, never from design pixels.
    $statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $setSpinner = {
        param([bool]$On)
        if ($null -eq $spinState['BaseLeft']) {
            $spinState.BaseLeft = $statusLabel.Left
            $spinState.BaseWidth = $statusLabel.Width
        }
        if ($On) {
            $gap = [int][Math]::Max(3, [Math]::Round($spinner.Width / 4))
            $spinner.Left = $spinState.BaseLeft
            $spinner.Top = $statusLabel.Top + [int][Math]::Floor(($statusLabel.Height - $spinner.Height) / 2)
            $statusLabel.Left = $spinner.Right + $gap
            $statusLabel.Width = $spinState.BaseLeft + $spinState.BaseWidth - $statusLabel.Left
            $spinner.Visible = $true
            $spinTimer.Start()
        } else {
            $spinTimer.Stop()
            $spinner.Visible = $false
            $statusLabel.Left = $spinState.BaseLeft
            $statusLabel.Width = $spinState.BaseWidth
        }
    }.GetNewClosure()

    $progressTrack = New-Object System.Windows.Forms.Panel
    $progressTrack.SetBounds(20, 393, 520, 3)
    $progressTrack.BackColor = [System.Drawing.Color]::FromArgb(0x2E, 0x2F, 0x36)
    $progressFill = New-Object System.Windows.Forms.Panel
    $progressFill.SetBounds(0, 0, 0, 3)
    $progressFill.BackColor = $accent
    [void]$progressTrack.Controls.Add($progressFill)
    [void]$form.Controls.Add($progressTrack)

    $installButton = New-Object System.Windows.Forms.Button
    $installButton.SetBounds(230, 402, 112, 32)
    $installButton.Text = 'Установить'
    $installButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $installButton.BackColor = $accent
    $installButton.ForeColor = [System.Drawing.Color]::White
    [void]$form.Controls.Add($installButton)
    $uninstallButton = New-Object System.Windows.Forms.Button
    $uninstallButton.SetBounds(350, 402, 100, 32)
    $uninstallButton.Text = 'Удалить'
    $uninstallButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $uninstallButton.BackColor = $panelBg
    $uninstallButton.ForeColor = $textColor
    [void]$form.Controls.Add($uninstallButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.SetBounds(458, 402, 82, 32)
    $cancelButton.Text = 'Отмена'
    $cancelButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $cancelButton.BackColor = $panelBg
    $cancelButton.ForeColor = $textColor
    [void]$form.Controls.Add($cancelButton)
    $cancelButton.add_Click({ $form.Close() }.GetNewClosure())

    $installed = Test-Path -LiteralPath (Join-Path $installText.Text 'settings.json')
    if ($installed) { $installButton.Text = 'Обновить' }
    $workerState = @{
        Process = $null
        Kind = ''
        Busy = $false
        Progress = 0
        Target = 0
        LogPath = Join-Path $env:TEMP 'zapret-lazy-setup\setup.log'
        LogOffset = [long]0
        LastError = ''
    }
    $form.Tag = $workerState
    $setBusy = {
        param([bool]$Busy, [string]$Text)
        $workerState.Busy = $Busy
        foreach ($control in @($installButton, $uninstallButton, $browseInstall, $browseDonor, $installText, $donorText, $cancelButton)) { $control.Enabled = -not $Busy }
        & $setSpinner $Busy
        $statusLabel.Text = $Text
    }.GetNewClosure()
    $setProgress = {
        param([int]$Value, [string]$Text)
        if ($Value -gt $workerState.Target) { $workerState.Target = $Value }
        if ($Value -ge 100) { $workerState.Progress = 100 }
        $progressFill.Width = [int]($progressTrack.Width * $workerState.Progress / 100)
        if ($Text) { $statusLabel.Text = $Text }
    }.GetNewClosure()
    $workerTimer = New-Object System.Windows.Forms.Timer
    $workerTimer.Interval = 120
    $startWorker = {
        param([string]$Kind, [string[]]$Arguments)
        $workerState.Kind = $Kind
        $workerState.Progress = 0
        $workerState.Target = 0
        $workerState.LastError = ''
        $workerState.LogOffset = 0
        if (Test-Path -LiteralPath $workerState.LogPath) {
            $workerState.LogOffset = (Get-Item -LiteralPath $workerState.LogPath).Length
        }
        $progressFill.Width = 0
        $workerState.Process = Start-SetupWorkerProcess -Arguments $Arguments
        $workerTimer.Start()
    }.GetNewClosure()

    $workerTimer.add_Tick({
        try {
            if ($workerState.Progress -lt $workerState.Target) {
                $workerState.Progress++
                $progressFill.Width = [int]($progressTrack.Width * $workerState.Progress / 100)
            }
            if ($null -eq $workerState.Process) { return }
            $delta = Read-SetupLogDelta -State $workerState
            foreach ($line in @($delta -split "`r?`n")) {
                if ($line -notmatch '\[ZAP-AUTO-SETUP\]\s+\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}\s+(?<event>\S+)') { continue }
                $eventName = [string]$Matches.event
                if ($eventName -eq 'SetupFailed') { $workerState.LastError = $line }
                $milestone = Get-SetupProgressMilestone -Kind $workerState.Kind -Event $eventName
                if ($null -ne $milestone) { & $setProgress ([int]$milestone[0]) ([string]$milestone[1]) }
            }
            if (-not $workerState.Process.HasExited) { return }
            $exitCode = $workerState.Process.ExitCode
            $workerState.Process.Dispose()
            $workerState.Process = $null
            $workerTimer.Stop()
            if ($exitCode -eq 0) {
                & $setSpinner $false
                & $setProgress 100 (& { if ($workerState.Kind -eq 'uninstall') { 'Удаление завершено.' } else { 'Установка завершена.' } })
                $workerState.Busy = $false
                $form.Tag.Busy = $false
                if ($workerState.Kind -eq 'uninstall') {
                    Write-SetupLog 'GuiUninstallDone' "dir=$($installText.Text)"
                    [void](Show-SetupDialog -Owner $form -Title 'Удаление завершено' -Message 'zlazy удалён вместе с задачами и компонентами.' -Kind success)
                } else {
                    [void](Show-SetupDialog -Owner $form -Title 'Установка завершена' -Message 'Установка прошла успешно, zlazy запущен.' -Kind success)
                }
                $form.Dispose()
                return
            }
            $operation = if ($workerState.Kind -eq 'uninstall') { 'удаления' } else { 'установки' }
            $reason = $workerState.LastError
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "Worker завершился с кодом $exitCode." }
            Write-SetupLog 'GuiWorkerFailed' "kind=$($workerState.Kind) exitCode=$exitCode"
            & $setBusy $false "Ошибка $operation."
            [void](Show-SetupDialog -Owner $form -Title "Ошибка $operation" -Message $reason -Kind error)
        } catch {
            Write-SetupLog 'GuiWorkerPollFailed' $_.Exception.Message
        }
    }.GetNewClosure())
    $form.add_FormClosing({
        param($sender, $e)
        if ($form.Tag.Busy) {
            $e.Cancel = $true
            $statusLabel.Text = 'Дождитесь завершения текущей операции.'
        }
    }.GetNewClosure())

    $installButton.add_Click({
        try {
            if ($workerState.Busy) { return }
            if ([string]::IsNullOrWhiteSpace($installText.Text)) { throw 'Выберите папку установки.' }
            $workerArgs = @('/Quiet', ('/InstallDir=' + $installText.Text.Trim()))
            if (-not [string]::IsNullOrWhiteSpace($donorText.Text)) { $workerArgs += '/DonorPath=' + $donorText.Text.Trim() }
            if (-not $desktopCheck.Checked) { $workerArgs += '/NoDesktopShortcut' }
            if (-not $startMenuCheck.Checked) { $workerArgs += '/NoStartMenuShortcut' }
            & $setBusy $true 'Подготовка к установке…'
            & $startWorker 'install' $workerArgs
        } catch {
            Write-SetupLog 'GuiInstallFailed' $_.Exception.Message
            & $setBusy $false 'Ошибка установки.'
            [void](Show-SetupDialog -Owner $form -Title 'Ошибка установки' -Message $_.Exception.Message -Kind error)
        }
    }.GetNewClosure())
    $uninstallButton.add_Click({
        if ($workerState.Busy) { return }
        $answer = Show-SetupDialog -Owner $form -Title 'Удаление zlazy' -Message 'Удалить zlazy, его задачи и компоненты?' -Kind confirm -ConfirmText 'Удалить'
        if (-not $answer) { return }
        try {
            $workerArgs = @('/Quiet', '/Uninstall', ('/InstallDir=' + $installText.Text.Trim()))
            & $setBusy $true 'Подготовка к удалению…'
            & $startWorker 'uninstall' $workerArgs
        } catch {
            Write-SetupLog 'GuiUninstallFailed' $_.Exception.Message
            & $setBusy $false 'Ошибка удаления.'
            [void](Show-SetupDialog -Owner $form -Title 'Ошибка удаления' -Message $_.Exception.Message -Kind error)
        }
    }.GetNewClosure())
    [void][System.Windows.Forms.Application]::Run($form)
}

# ---------------------------------------------------------------------------
$setupArgs = @($args | Where-Object { $_ -is [string] } | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ine '-end' })
$opts = ConvertFrom-SetupArgs -RawArgs $setupArgs
try {
    if (-not (Test-IsElevated)) {
        $forwarded = @($setupArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }) -join ' '
        $currentExe = [Environment]::GetCommandLineArgs()[0]
        if ([IO.Path]::GetFileNameWithoutExtension($currentExe) -match '^powershell') {
            $scriptArgs = '-NoProfile -ExecutionPolicy Bypass -File "{0}" {1}' -f $PSCommandPath, $forwarded
            Start-Process -FilePath $currentExe -ArgumentList $scriptArgs -Verb RunAs
        } elseif ($forwarded) {
            Start-Process -FilePath $currentExe -ArgumentList $forwarded -Verb RunAs
        } else {
            Start-Process -FilePath $currentExe -Verb RunAs
        }
        Write-SetupLog 'ElevationRequested'
        exit 0
    }

    Write-SetupLog 'SetupStart' ("args=" + ($args -join ' '))
    if ($opts.uninstall) {
        $dir = Resolve-InstallDir -Requested $opts.installDir
        Uninstall-Autopilot -InstallDir $dir -KeepData $opts.keepData
        Write-SetupLog 'UninstallDone' "dir=$dir"
        exit 0
    }
    $meaningfulArgs = @($setupArgs)
    if (-not $opts.quiet -and $meaningfulArgs.Count -eq 0) {
        Show-SetupGui
    } else {
        [void](Invoke-SetupInstallation -Options $opts -DesktopShortcut $opts.desktopShortcut -StartMenuShortcut $opts.startMenuShortcut)
    }
    exit 0
} catch {
    Write-SetupLog 'SetupFailed' $_.Exception.Message
    Write-SetupLog 'SetupFailedAt' (($_.InvocationInfo.PositionMessage -split "`r?`n")[0])
    Write-SetupLog 'SetupStack' (($_.ScriptStackTrace -split "`r?`n" | Where-Object { $_ -notmatch '^\s*$' }) -join ' <= ')
    if (-not $opts.quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        $fatalText = ($_.Exception.Message + "`n`nЛог: " + (Join-Path $env:TEMP 'zapret-lazy-setup\setup.log'))
        try { [void](Show-SetupDialog -Owner $null -Title 'Ошибка zlazy Setup' -Message $fatalText -Kind error) } catch {
            [void][System.Windows.Forms.MessageBox]::Show($fatalText, 'Ошибка zlazy Setup', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
    exit 1
}
