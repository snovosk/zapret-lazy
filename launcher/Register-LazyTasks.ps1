# Register-LazyTasks.ps1 — scheduled task registration for zapret-lazy.
#
# Default (no switches): idempotently register two autostart tasks using the
# unified zlazy.exe and publish the selected desktop/Start Menu shortcuts:
#   ZapretLazyEngine — SYSTEM / Highest, zlazy.exe --engine, restart x3.
#   ZapretLazyTray   — interactive / Limited, zlazy.exe --tray.
# -UseScripts instead registers %SystemRoot%\System32\wscript.exe
# launcher.vbs engine|tray — the fallback for hosts where Smart App Control or
# another policy blocks unsigned executables (scripts are not blocked).
# Every action uses an absolute path (never PATH-resolvable bare names), and
# after registration each action is read back and verified before the task is
# trusted (Launcher VerifiedAction / VerifiedActionMismatch /
# VerifiedActionUnavailable). Self-elevates through UAC when started without
# administrator rights.
#
# Switches:
#   -Admin       internal marker for the elevated relaunch (prevents re-elevation).
#   -Unregister  remove both tasks.
#   -Status      print current registration state (read-only, never elevates).
#   -UseScripts  register wscript+launcher.vbs actions instead of zlazy.exe.
#   -NoDesktopShortcut / -NoStartMenuShortcut suppress the selected shortcuts.

[CmdletBinding()]
param(
    [switch]$Admin,
    [switch]$Unregister,
    [switch]$Status,
    [switch]$UseScripts,
    [switch]$NoDesktopShortcut,
    [switch]$NoStartMenuShortcut
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PS2EXE -noConsole renders every Write-Progress (Expand-Archive, first-use
# module loading) as a separate white window: progress is never shown.
$ProgressPreference = 'SilentlyContinue'

$script:ModuleName      = 'Launcher'
$script:EngineTaskName  = 'ZapretLazyEngine'
$script:TrayTaskName    = 'ZapretLazyTray'
# Pre-rename task names (zapret-autopilot): removed whenever registration or
# unregistration runs, so an old entry can never shadow the new one.
$script:LegacyTaskNames = @('ZapretAutoEngine', 'ZapretAutoTray')
$script:EngineDelaySec  = 0
$script:TrayDelaySec    = 10
$script:RestartCount    = 3
$script:RestartInterval = New-TimeSpan -Minutes 1
$script:UnlimitedRun    = [TimeSpan]::Zero

# Project root is the parent of this script's folder (launcher\ sits under root).
$script:ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:LauncherVbs = Join-Path $PSScriptRoot 'launcher.vbs'

# Absolute interpreter path for script-mode actions. A bare 'wscript.exe' would
# be resolved through PATH when the task runs and could be redirected by any
# writer on the PATH; the System32 copy cannot.
$script:WscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'

# Compiled entry points (preferred). Script mode (-UseScripts) is the fallback
# for hosts where Smart App Control or SRP blocks unsigned executables.
$script:EngineExe = Join-Path $script:ProjectRoot 'zlazy.exe'
$script:TrayExe = $script:EngineExe

# Shortcuts launch the tray mode of the same unified executable.
$script:ShortcutName = 'zlazy.lnk'

function Get-TaskActionSpec {
    # Action template for one task: absolute Execute path, Argument string,
    # the executable the read-back verification must match, and a description tag.
    param([Parameter(Mandatory = $true)][string]$Mode)
    if ($UseScripts) {
        return @{
            Execute    = $script:WscriptExe
            Argument   = ('"{0}" {1}' -f $script:LauncherVbs, $Mode)
            Expected   = $script:WscriptExe
            Kind       = 'scripts'
            Description = ('zapret-lazy {0} bootstrap (launcher.vbs {0})' -f $Mode)
        }
    }
    $exe = & { if ($Mode -eq 'engine') { $script:EngineExe } else { $script:TrayExe } }
    return @{
        Execute    = $exe
        Argument   = ('--{0}' -f $Mode)
        Expected   = $exe
        Kind       = 'exe'
        Description = ('zlazy {0} (zlazy.exe --{0})' -f $Mode)
    }
}

function Get-DesktopShortcutPath {
    # Registration runs elevated under the installing account — the same
    # account the tray task runs as — so that user's desktop is the right place.
    $desktop = [Environment]::GetFolderPath('Desktop')
    if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }
    return (Join-Path $desktop $script:ShortcutName)
}

function Get-StartMenuShortcutPath {
    $programs = [Environment]::GetFolderPath('Programs')
    if (-not $programs) { $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs' }
    return (Join-Path $programs $script:ShortcutName)
}

function Publish-Shortcut {
    param([Parameter(Mandatory = $true)][string]$Path)
    $spec = Get-TaskActionSpec -Mode 'tray'
    try {
        $parent = Split-Path $Path -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
        $shell = New-Object -ComObject 'WScript.Shell'
        $link = $shell.CreateShortcut($Path)
        $link.TargetPath = $spec.Execute
        if ($spec.Argument) { $link.Arguments = $spec.Argument }
        $link.WorkingDirectory = $script:ProjectRoot
        $brandIcon = Join-Path $script:ProjectRoot 'assets\zapret-lazy.ico'
        $link.IconLocation = ('{0},0' -f (& { if (Test-Path -LiteralPath $brandIcon) { $brandIcon } elseif ($UseScripts) { $script:WscriptExe } else { $script:TrayExe } }))
        $link.Description = 'zlazy tray'
        $link.Save()
        Write-Log $script:ModuleName 'ShortcutPublished' "path=$Path"
    } catch {
        Write-Log $script:ModuleName 'ShortcutFailed' "path=$Path error=$($_.Exception.Message)"
    }
}

function Remove-Shortcuts {
    foreach ($path in @((Get-DesktopShortcutPath), (Get-StartMenuShortcutPath), (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Zapret Lazy.lnk'))) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            Write-Log $script:ModuleName 'ShortcutRemoved' "path=$path"
        }
    }
}

function Test-ValidProjectRoot {
    param([Parameter(Mandatory = $true)][string]$Path)
    # A resolved root must never contain a parent-traversal segment; finding
    # one means path resolution behaved unexpectedly and we must not continue.
    return -not (($Path -split '[\\/]') -contains '..')
}

function Test-WscriptAvailable {
    if (Test-Path -LiteralPath $script:WscriptExe) { return $true }
    Write-Log $script:ModuleName 'WscriptMissing' "path=$script:WscriptExe"
    return $false
}

Import-Module (Join-Path $script:ProjectRoot 'src\Config.psm1') -Force

if (-not (Test-ValidProjectRoot -Path $script:ProjectRoot)) {
    Write-Log $script:ModuleName 'ProjectRootInvalid' "path=$script:ProjectRoot"
    throw "Project root '$script:ProjectRoot' contains a '..' segment after resolution."
}

function Get-CurrentUserName {
    return [Security.Principal.WindowsIdentity]::GetCurrent().Name
}

function Invoke-NativeQuiet {
    # Run a native command silently and return its exit code.
    # $ErrorActionPreference = 'Stop' turns native stderr into a thrown
    # NativeCommandError even when redirected, so it is relaxed for the call
    # and native stderr is discarded via 2>$null.
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

function Test-TaskRegistered {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        Get-ScheduledTask -TaskName $Name -ErrorAction Stop | Out-Null
        return $true
    } catch {
        # Cmdlet missing or task absent — confirm with schtasks.exe before saying no;
        # without this, the schtasks fallback backend below could never reach the
        # post-registration verification step on hosts without the cmdlets.
        $exitCode = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/Query', '/TN', $Name)
        return ($exitCode -eq 0)
    }
}

function Remove-AutopilotTask {
    param([Parameter(Mandatory = $true)][string]$Name)
    if (-not (Test-TaskRegistered -Name $Name)) { return $false }
    try {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false
    } catch {
        # ScheduledTasks module unavailable — fall back to schtasks.exe.
        $exitCode = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/Delete', '/F', '/TN', $Name)
        if ($exitCode -ne 0) { throw "schtasks.exe /Delete failed for '$Name' (exit $exitCode)." }
    }
    Write-Log $script:ModuleName 'Unregistered' "task=$Name"
    return $true
}

function Register-EngineTaskCmdlets {
    $spec = Get-TaskActionSpec -Mode 'engine'
    if ($null -ne $spec.Argument) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
    } else {
        $action = New-ScheduledTaskAction -Execute $spec.Execute
    }
    $trigger = New-ScheduledTaskTrigger -AtStartup
    if ($script:EngineDelaySec -gt 0) { $trigger.Delay = ('PT{0}S' -f $script:EngineDelaySec) }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -RestartCount $script:RestartCount -RestartInterval $script:RestartInterval `
        -ExecutionTimeLimit $script:UnlimitedRun
    Register-ScheduledTask -TaskName $script:EngineTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $spec.Description | Out-Null
}

function Register-TrayTaskCmdlets {
    $user = Get-CurrentUserName
    $spec = Get-TaskActionSpec -Mode 'tray'
    if ($null -ne $spec.Argument) {
        $action = New-ScheduledTaskAction -Execute $spec.Execute -Argument $spec.Argument
    } else {
        $action = New-ScheduledTaskAction -Execute $spec.Execute
    }
    $trigger = New-ScheduledTaskTrigger -AtLogon -User $user
    $trigger.Delay = ('PT{0}S' -f $script:TrayDelaySec)
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -Hidden -ExecutionTimeLimit $script:UnlimitedRun
    Register-ScheduledTask -TaskName $script:TrayTaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $spec.Description | Out-Null
}

function Format-SchtasksPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    # schtasks.exe /TR quoting helper. Doubling embedded quotes is only needed
    # when the path contains whitespace: Windows PowerShell 5.1 does not escape
    # embedded quotes for native commands, so each pair survives as one literal
    # quote once CommandLineToArgvW parses the /TR value.
    if ($Path -match '\s') { return ('""{0}""' -f $Path) }
    return $Path
}

function Register-TaskSchtasksFallback {
    # schtasks.exe fallback for hosts without the ScheduledTasks module. Uses
    # the same absolute System32 interpreter path as the cmdlet backend.
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][string]$RunAs
    )
    $spec = Get-TaskActionSpec -Mode $Mode
    if ($spec.Kind -eq 'exe') {
        $taskRun = ('{0} {1}' -f (Format-SchtasksPath $spec.Execute), $spec.Argument)
    } else {
        $taskRun = '{0} {1} {2}' -f (Format-SchtasksPath $spec.Execute), (Format-SchtasksPath $script:LauncherVbs), $Mode
    }
    $delay = '0000:{0:D2}' -f (& { if ($Mode -eq 'engine') { $script:EngineDelaySec } else { $script:TrayDelaySec } })
    $schedule = 'ONLOGON'
    if ($Mode -eq 'engine') { $schedule = 'ONSTART' }
    $arguments = @('/Create', '/F', '/TN', $Name, '/TR', $taskRun, '/SC', $schedule)
    if ($Mode -eq 'tray' -or $script:EngineDelaySec -gt 0) { $arguments += @('/DELAY', $delay) }
    if ($RunAs -eq 'SYSTEM') {
        $arguments += @('/RU', 'SYSTEM', '/RL', 'HIGHEST')
    } else {
        $arguments += @('/RU', $RunAs)
    }
    $exitCode = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments $arguments
    if ($exitCode -ne 0) { throw "schtasks.exe /Create failed for '$Name' (exit $exitCode)." }
    Write-Log $script:ModuleName 'FallbackUsed' "task=$Name backend=schtasks"
}

function Get-TaskActionExecutable {
    param([Parameter(Mandatory = $true)][string]$Name)
    # Read back the first action's executable: ScheduledTasks cmdlets when
    # available, otherwise schtasks.exe /XML (the hosts that need the schtasks
    # registration fallback have no module). $null when neither works.
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        foreach ($action in $task.Actions) { return [string]$action.Execute }
        return $null
    } catch {
    }
    $xmlText = Get-TaskActionXml -Name $Name
    if ($null -ne $xmlText) { return (ConvertFrom-TaskXmlCommand -XmlText $xmlText) }
    return $null
}

function Get-TaskActionArgument {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        foreach ($action in $task.Actions) { return [string]$action.Arguments }
        return $null
    } catch { }
    $xmlText = Get-TaskActionXml -Name $Name
    if ($null -ne $xmlText) {
        try {
            [xml]$doc = $XmlText
            $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
            $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
            $node = $doc.SelectSingleNode('//t:Arguments', $ns)
            if ($null -ne $node) { return $node.InnerText }
            return ''
        } catch { return $null }
    }
    return $null
}

function Get-TaskActionXml {
    param([Parameter(Mandatory = $true)][string]$Name)
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = (& schtasks.exe /Query /TN $Name /XML 2>$null | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or -not $output) { return $null }
        return $output
    } finally {
        $ErrorActionPreference = $previousPreference
    }
}

function ConvertFrom-TaskXmlCommand {
    param([Parameter(Mandatory = $true)][string]$XmlText)
    # Extract <Command> from a schtasks /XML task report (Task Scheduler schema).
    try {
        [xml]$doc = $XmlText
        $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $node = $doc.SelectSingleNode('//t:Command', $ns)
        if ($null -eq $node) { return $null }
        return $node.InnerText
    } catch {
        return $null
    }
}

function Register-LazyTasks {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][scriptblock]$RegisterViaCmdlets,
        [Parameter(Mandatory = $true)][scriptblock]$RegisterViaSchtasks
    )
    if (Test-TaskRegistered -Name $Name) {
        Write-Log $script:ModuleName 'TaskExists' "task=$Name action=reregister"
        # Remove via the fallback-aware helper: on hosts without the cmdlets the
        # plain Unregister-ScheduledTask call below would throw and abort the
        # re-registration.
        Remove-AutopilotTask -Name $Name | Out-Null
    }
    try {
        & $RegisterViaCmdlets
    } catch {
        Write-Log $script:ModuleName 'RegisterFallback' "task=$Name error=$($_.Exception.Message)"
        & $RegisterViaSchtasks
    }
    if (-not (Test-TaskRegistered -Name $Name)) {
        Write-Log $script:ModuleName 'RegisterFailed' "task=$Name"
        throw "Failed to register scheduled task '$Name'."
    }
    # Fail closed: a SYSTEM task whose action cannot be proven to be the
    # System32 interpreter is removed rather than left unverified.
    $executable = Get-TaskActionExecutable -Name $Name
    if ($null -eq $executable) {
        Write-Log $script:ModuleName 'VerifiedActionUnavailable' "task=$Name"
        try { Remove-AutopilotTask -Name $Name | Out-Null } catch {
            Write-Log $script:ModuleName 'VerificationCleanupFailed' "task=$Name error=$($_.Exception.Message)"
        }
        throw "Registered task '$Name' but its action executable could not be read back for verification; the task was removed."
    }
    $spec = Get-TaskActionSpec -Mode $Mode
    if (-not [string]::Equals($executable, $spec.Expected, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Log $script:ModuleName 'VerifiedActionMismatch' "task=$Name executable=$executable expected=$($spec.Expected)"
        try { Remove-AutopilotTask -Name $Name | Out-Null } catch {
            Write-Log $script:ModuleName 'VerificationCleanupFailed' "task=$Name error=$($_.Exception.Message)"
        }
        throw "Task '$Name' action executable '$executable' does not match '$($spec.Expected)'; the task was removed."
    }
    $actualArgument = Get-TaskActionArgument -Name $Name
    $expectedArgument = [string]$spec.Argument
    if ($null -eq $actualArgument) { $actualArgument = '' }
    if (-not [string]::Equals($actualArgument, $expectedArgument, [StringComparison]::Ordinal)) {
        Write-Log $script:ModuleName 'VerifiedActionMismatch' "task=$Name argument=$actualArgument expected=$expectedArgument"
        try { Remove-AutopilotTask -Name $Name | Out-Null } catch {
            Write-Log $script:ModuleName 'VerificationCleanupFailed' "task=$Name error=$($_.Exception.Message)"
        }
        throw "Task '$Name' arguments do not match the requested mode; the task was removed."
    }
    Write-Log $script:ModuleName 'VerifiedAction' "task=$Name executable=$executable argument=$actualArgument kind=$($spec.Kind)"
    Write-Log $script:ModuleName 'Registered' "task=$Name mode=$Mode"
}

function Get-TaskSummary {
    param([Parameter(Mandatory = $true)][string]$Name)
    try {
        $task = Get-ScheduledTask -TaskName $Name -ErrorAction Stop
        return ('registered (state={0}, principal={1}, runLevel={2})' -f `
            $task.State, $task.Principal.UserId, $task.Principal.RunLevel)
    } catch {
        # Cmdlet missing or task absent — confirm with schtasks.exe before saying no.
        $exitCode = Invoke-NativeQuiet -FilePath 'schtasks.exe' -Arguments @('/Query', '/TN', $Name)
        if ($exitCode -eq 0) { return 'registered (details unavailable)' }
        return 'not registered'
    }
}

function Show-AutopilotStatus {
    Write-Log $script:ModuleName 'Status' 'action=query'
    foreach ($name in @($script:EngineTaskName, $script:TrayTaskName)) {
        Write-Host ("{0} : {1}" -f $name, (Get-TaskSummary -Name $name))
    }
}

function Remove-LegacyTasks {
    foreach ($legacy in $script:LegacyTaskNames) {
        try {
            $task = Get-ScheduledTask -TaskName $legacy -ErrorAction Stop
            Unregister-ScheduledTask -TaskName $legacy -Confirm:$false -ErrorAction Stop
            Write-Log $script:ModuleName 'LegacyTaskRemoved' "task=$legacy"
        } catch { }
    }
}

function Invoke-AutopilotTaskRegistration {
    Remove-LegacyTasks
    if ($UseScripts) {
        if (-not (Test-WscriptAvailable)) {
            throw "Interpreter '$script:WscriptExe' was not found; refusing to register scheduled tasks."
        }
        Write-Log $script:ModuleName 'ModeSelected' 'kind=scripts'
    } else {
        foreach ($exe in @($script:EngineExe, $script:TrayExe)) {
            if (-not (Test-Path -LiteralPath $exe)) {
                Write-Log $script:ModuleName 'ExeMissing' "path=$exe"
                throw ("Executable '{0}' not found. Run build\Build-Exe.ps1 first, or register script-mode tasks with -UseScripts." -f $exe)
            }
        }
        Write-Log $script:ModuleName 'ModeSelected' 'kind=exe'
    }
    Register-LazyTasks -Name $script:EngineTaskName -Mode 'engine' `
        -RegisterViaCmdlets { Register-EngineTaskCmdlets } `
        -RegisterViaSchtasks { Register-TaskSchtasksFallback -Name $script:EngineTaskName -Mode 'engine' -RunAs 'SYSTEM' }
    Register-LazyTasks -Name $script:TrayTaskName -Mode 'tray' `
        -RegisterViaCmdlets { Register-TrayTaskCmdlets } `
        -RegisterViaSchtasks { Register-TaskSchtasksFallback -Name $script:TrayTaskName -Mode 'tray' -RunAs (Get-CurrentUserName) }
    if (-not $NoDesktopShortcut) { Publish-Shortcut -Path (Get-DesktopShortcutPath) }
    if (-not $NoStartMenuShortcut) { Publish-Shortcut -Path (Get-StartMenuShortcutPath) }
}

try {
    if ($Status) {
        Show-AutopilotStatus
        return
    }

    if (-not (Test-IsAdmin)) {
        if ($Admin) {
            throw 'Administrator rights are required to manage zapret-lazy scheduled tasks.'
        }
        # Relaunch elevated, forwarding the requested action. The elevated copy
        # runs with -Admin so it does not prompt for UAC a second time.
        $elevatedArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Admin' -f $PSCommandPath
        if ($Unregister) { $elevatedArgs += ' -Unregister' }
        if ($UseScripts) { $elevatedArgs += ' -UseScripts' }
        if ($NoDesktopShortcut) { $elevatedArgs += ' -NoDesktopShortcut' }
        if ($NoStartMenuShortcut) { $elevatedArgs += ' -NoStartMenuShortcut' }
        Write-Log $script:ModuleName 'ElevationRequested' "reason=notAdmin script=$PSCommandPath"
        Start-Process -FilePath 'powershell.exe' -ArgumentList $elevatedArgs -Verb RunAs
        Write-Host 'A UAC prompt was raised; the requested action runs in an elevated window.'
        return
    }

    if ($Unregister) {
        Remove-LegacyTasks
        $removedEngine = Remove-AutopilotTask -Name $script:EngineTaskName
        $removedTray = Remove-AutopilotTask -Name $script:TrayTaskName
        Remove-Shortcuts
        if (-not $removedEngine -and -not $removedTray) {
            Write-Host 'No zapret-lazy scheduled tasks were registered.'
        }
        return
    }

    Invoke-AutopilotTaskRegistration
    Write-Host ("Registered '{0}' and '{1}'." -f $script:EngineTaskName, $script:TrayTaskName)
} catch {
    Write-Log $script:ModuleName 'Error' "message=$($_.Exception.Message)"
    throw
}
