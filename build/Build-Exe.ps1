# Build-Exe.ps1 — merges engine and tray into one dual-mode application and
# compiles it plus the separate GUI installer with PS2EXE.
# Output: <root>\zlazy.exe, <root>\zlazy-setup.exe
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File build\Build-Exe.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$staging = Join-Path $env:TEMP ('zapret-lazy-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $staging | Out-Null

# Identical-name functions/variables that are safe to merge (same values/behavior,
# verified by cross-module review 2026-11-18). Anything else duplicated fails the build.
$script:AllowedDuplicates = @('Enable-Tls12')
$script:AllowedDuplicateVars = @('$script:PingTimeoutMs', '$script:ServiceName', '$script:ServiceStartTimeoutSec', '$script:ServicePollDelaySec')

function Remove-ExportModuleMember {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -match '^\s*Export-ModuleMember\b') {
            while ($Lines[$i].EndsWith('`')) { $i++ }
            $i++
            continue
        }
        $out.Add($Lines[$i])
        $i++
    }
    return $out
}

function Remove-ConfigImports {
    param([string[]]$Lines)
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $Lines) {
        if ($line -match 'Import-Module.*Config\.psm1') { continue }
        $out.Add($line)
    }
    return $out
}

function Remove-AutopilotImportBlock {
    param([string[]]$Lines)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '# --- \(0\) Import all') { $start = $i; break }
    }
    if ($start -lt 0) { throw 'Autopilot import block anchor not found' }
    $end = -1
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s{4}\}\s*$') { $end = $i; break }
    }
    if ($end -lt 0) { throw 'Autopilot import block end not found' }
    $out = New-Object System.Collections.Generic.List[string]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($i -ge $start -and $i -le $end) { continue }
        $out.Add($Lines[$i])
    }
    return $out
}

function Remove-LaterFunctionDefinition {
    # Drop a duplicate "function NAME {" block; keep the FIRST definition overall.
    param([string[]]$Lines, [string]$Name)
    $out = New-Object System.Collections.Generic.List[string]
    $seen = $false
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -match ("^function " + [regex]::Escape($Name) + " \{" + '$')) {
            if (-not $seen) {
                $seen = $true
                $out.Add($Lines[$i]); $i++
                continue
            }
            # skip whole function block: until matching closing brace at column 0
            $i++
            while ($i -lt $Lines.Count -and $Lines[$i] -notmatch '^\}') { $i++ }
            $i++ # skip the closing brace
            continue
        }
        $out.Add($Lines[$i])
        $i++
    }
    return $out
}

function Patch-GetRoot {
    param([string]$Text)
    $newBody = @'
function Get-Root {
    # Merged exe build: project root = the executable's own directory. PS2EXE
    # does not set $PSScriptRoot inside the compiled host, so fall back to the
    # process image path, then to the current directory (last resort).
    if (-not $script:Root) {
        $base = $PSScriptRoot
        if (-not $base) {
            try { $base = [IO.Path]::GetDirectoryName([Environment]::GetCommandLineArgs()[0]) } catch { }
        }
        if (-not $base) { $base = (Get-Location).Path }
        $script:Root = $base
    }
    return $script:Root
}
'@
    return [regex]::Replace($Text, '(?ms)^function Get-Root \{.*?\n\}', $newBody.TrimEnd(), 1)
}

function Merge-Parts {
    param([string[]]$PartFiles, [string]$OutFile)
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($file in $PartFiles) {
        $lines = [System.IO.File]::ReadAllLines($file)
        $lines = Remove-ExportModuleMember $lines
        $lines = Remove-ConfigImports $lines
        if ((Split-Path $file -Leaf) -eq 'Autopilot.ps1') {
            $lines = Remove-AutopilotImportBlock $lines
        }
        foreach ($l in $lines) {
            if ($l -match '^Invoke-Zlazy(Engine|Tray)$') { continue }
            $all.Add($l)
        }
        $all.Add('')
        $all.Add(("# ===== merged part: " + (Split-Path $file -Leaf) + " ====="))
        $all.Add('')
    }
    $text = ($all -join "`r`n")

    foreach ($dup in $script:AllowedDuplicates) {
        $count = ([regex]::Matches($text, ('(?m)^function ' + [regex]::Escape($dup) + ' \{$'))).Count
        if ($count -gt 1) {
            $text = ($text -join "`r`n") | Out-Null
            $arr = ($text -split "`r`n")
            $arr = Remove-LaterFunctionDefinition -Lines $arr -Name $dup
            $text = ($arr -join "`r`n")
            Write-Host ("Duplicate definition dropped (allow-listed): " + $dup)
        }
    }

    $text = Patch-GetRoot $text

    # Collision gate: every function name must be unique after merges.
    $names = [regex]::Matches($text, '(?m)^function ([A-Za-z_-]+) \{') | ForEach-Object { $_.Groups[1].Value }
    $dupes = $names | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name }
    if ($dupes) { throw ('Function name collisions in merged script: ' + ($dupes -join ', ')) }

    [System.IO.File]::WriteAllText($OutFile, $text, (New-Object System.Text.UTF8Encoding($true)))
    return $OutFile
}

function Invoke-Ps2Exe {
    param([string]$InputFile, [string]$OutputFile, [string]$Title, [string]$Description)
    $tool = Join-Path $PSScriptRoot 'tools\ps2exe.ps1'
    if (-not (Test-Path $tool)) { throw ('PS2EXE not found: ' + $tool) }
    # tools/ps2exe.ps1 only DEFINES Invoke-ps2exe; dot-source then call.
    # Brand icon (design/zapret-icon via assets) baked in when present.
    $iconArg = ''
    $iconFile = Join-Path $root 'assets\zapret-lazy.ico'
    if (Test-Path -LiteralPath $iconFile) { $iconArg = " -iconFile '$iconFile'" }
    $inner = ". '$tool'; Invoke-ps2exe -inputFile '$InputFile' -outputFile '$OutputFile' -noConsole -noOutput -noError -STA -title '$Title' -product 'zapret-lazy' -company 'zapret-lazy' -version '1.3.8.0' -description '$Description'$iconArg"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($inner)
    $encoded = [Convert]::ToBase64String($bytes)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ('PS2EXE failed for ' + $InputFile + ' exit=' + $p.ExitCode) }
    if (-not (Test-Path $OutputFile)) { throw ('PS2EXE did not produce ' + $OutputFile) }
}

# --- dual-mode application ---
$appParts = @('Config.psm1', 'UpdateManager.psm1', 'Preflight.psm1', 'StrategyEngine.psm1', 'ServiceManager.psm1', 'Notify.psm1', 'Autopilot.ps1') | ForEach-Object { Join-Path $root ("src\" + $_) }
$appParts += Join-Path $root 'tray\TrayApp.ps1'
$mergedOutDir = Join-Path $root 'build\merged'
if (-not (Test-Path $mergedOutDir)) { New-Item -ItemType Directory -Path $mergedOutDir | Out-Null }
$mergedApp = Merge-Parts -PartFiles $appParts -OutFile (Join-Path $mergedOutDir 'zlazy.merged.ps1')
$dispatcher = @'

$engineMode = $false
foreach ($argument in $args) {
    if ([string]$argument -match '^--?engine$') { $engineMode = $true }
}
$modeName = 'tray'
if ($engineMode) { $modeName = 'engine' }
Write-Log 'Launcher' 'ModeSelected' "mode=$modeName args=$($args -join ',') pid=$PID"
if ($engineMode) { Invoke-ZlazyEngine } else { Invoke-ZlazyTray }
'@
[System.IO.File]::AppendAllText($mergedApp, $dispatcher, (New-Object System.Text.UTF8Encoding($true)))

# --- parse gate on merged source ---
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($mergedApp, [ref]$tokens, [ref]$errs)
if ($errs.Count -gt 0) { throw ('Merged script parse errors: ' + $mergedApp + ' :: ' + ($errs | ForEach-Object { $_.Message } | Select-Object -First 3)) }
Write-Host ('Merged parse OK: ' + (Split-Path $mergedApp -Leaf) + ' (' + (Get-Item $mergedApp).Length + ' bytes)')

# --- compile ---
# Old separate entry points must not linger next to the unified application.
foreach ($legacyExe in @('ZapretAutoEngine.exe', 'ZapretAutoTray.exe', 'ZapretLazyEngine.exe', 'ZapretLazyTray.exe', 'Setup.exe')) {
    $legacyPath = Join-Path $root $legacyExe
    if (Test-Path -LiteralPath $legacyPath) {
        Remove-Item -LiteralPath $legacyPath -Force -ErrorAction Stop
        Write-Host ('Removed legacy ' + $legacyExe)
    }
}
Invoke-Ps2Exe -InputFile $mergedApp -OutputFile (Join-Path $root 'zlazy.exe') -Title 'zlazy' -Description 'Autonomous zapret strategy manager and tray widget'
Get-Item (Join-Path $root 'zlazy.exe') | ForEach-Object { Write-Host ($_.Name + ' ' + $_.Length + ' bytes') }

# --- setup package (embedded into zlazy-setup.exe) ---
$packagePath = Join-Path $root 'build\package.zip'
if (Test-Path $packagePath) { Remove-Item $packagePath -Force }
$packageItems = @('zlazy.exe', 'README.md', 'CHANGELOG.md', 'LICENSE', 'THIRD_PARTY_NOTICES.md', 'licenses', 'launcher', 'src', 'tray', 'docs', 'assets')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$pkg = [System.IO.Compression.ZipFile]::Open($packagePath, 'Create')
foreach ($i in $packageItems) {
    $srcItem = Join-Path $root $i
    if (Test-Path $srcItem -PathType Container) {
        Get-ChildItem $srcItem -Recurse -File | ForEach-Object {
            $rel = $i + '\' + ($_.FullName.Substring($srcItem.Length + 1))
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($pkg, $_.FullName, $rel) | Out-Null
        }
    } else {
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($pkg, $srcItem, $i) | Out-Null
    }
}
$pkg.Dispose()
Write-Host ('package.zip ' + (Get-Item $packagePath).Length + ' bytes')

# --- GUI installer (package embedded, extracted to %TEMP% at runtime) ---
function Invoke-Ps2ExeSetup {
    param([string]$InputFile, [string]$OutputFile, [string]$EmbedSource)
    $tool = Join-Path $PSScriptRoot 'tools\ps2exe.ps1'
    $embedEntry = ('@{''%TEMP%\zapret-lazy-setup\package.zip''=''' + $EmbedSource + '''}')
    $iconArg = ''
    $iconFile = Join-Path $root 'assets\zapret-lazy.ico'
    if (Test-Path -LiteralPath $iconFile) { $iconArg = " -iconFile '$iconFile'" }
    $inner = ". '$tool'; Invoke-ps2exe -inputFile '$InputFile' -outputFile '$OutputFile' -noConsole -STA -title 'zlazy Setup' -product 'zlazy' -company 'zlazy' -version '1.3.8.0' -description 'Installer for zlazy' -embedFiles $embedEntry$iconArg"
    $bytes = [System.Text.Encoding]::Unicode.GetBytes($inner)
    $encoded = [Convert]::ToBase64String($bytes)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encoded) -Wait -PassThru -NoNewWindow
    if ($p.ExitCode -ne 0) { throw ('PS2EXE failed for zlazy-setup.exe exit=' + $p.ExitCode) }
    if (-not (Test-Path $OutputFile)) { throw ('PS2EXE did not produce ' + $OutputFile) }
}

Invoke-Ps2ExeSetup -InputFile (Join-Path $root 'setup\Setup.ps1') -OutputFile (Join-Path $root 'zlazy-setup.exe') -EmbedSource $packagePath
Get-Item (Join-Path $root 'zlazy-setup.exe') | ForEach-Object { Write-Host ($_.Name + ' ' + $_.Length + ' bytes') }

Remove-Item -Recurse -Force $staging -ErrorAction SilentlyContinue
Write-Host 'BUILD OK'
