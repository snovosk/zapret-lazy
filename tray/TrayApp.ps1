# TrayApp.ps1 - user-facing tray icon + compact widget for zapret-lazy.
# User context, hidden start, no admin. Reads state/status.json (engine-owned),
# writes state/commands.json (atomic tmp+move), persists widget prefs via
# Get-Config/Save-Config (settings.json widget section). See docs/CONVENTIONS.md.
# Launch: launcher.vbs tray -> powershell -WindowStyle Hidden -File TrayApp.ps1

Set-StrictMode -Version Latest
# PS2EXE -noConsole renders every Write-Progress (Expand-Archive, first-use
# module loading) as a separate white window: progress is never shown.
$ProgressPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace ZapretLazy.Native -Name IconMethods -MemberDefinition '[DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);'
Add-Type -Namespace ZapretLazy.Native -Name WindowMethods -MemberDefinition '
[DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int index);
[DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int index, IntPtr value);'

Import-Module (Join-Path $PSScriptRoot '..\src\Config.psm1') -Force

# ---------------------------------------------------------------------------
# Constants (no magic numbers)
# ---------------------------------------------------------------------------
$script:TimerIntervalMs       = 2000
$script:PendingSelectionTimeoutSec = 20
$script:WidgetWidth           = 278
# Design v2 (design/spec.md 2026-11-19): card 278x186, three stepper fields
# (strat / game filter / ipset list), centered status row, footer 'zapret v…'.
$script:WidgetHeight          = 186
$script:WidgetCornerRadius    = 8
$script:HeaderHeight          = 26
$script:Margin                = 10
# Header (spec.md): fox 12x12 at (10,7); title (27,6);
# icon buttons: dots (236,7) 10x12, close (258,8) 10x10.
$script:HeaderLogoLeft        = 10
$script:HeaderLogoTop         = 7
$script:HeaderLogoSize        = 12
$script:HeaderTitleLeft       = 27
$script:MenuButtonBounds      = @(236, 7, 10, 12)
$script:CloseButtonBounds     = @(258, 8, 10, 10)
# Stepper fields: strat (10,37), game filter (10,65), ipset list (10,93),
# each 258x22 radius 5; arrows '<' '>' 6x9 at field-relative (232,7)/(244,7).
$script:RowStrategyTop        = 37
$script:RowGameFilterTop      = 65
$script:RowIpsetTop           = 93
$script:FieldHeight           = 22
$script:StepperArrowPrev      = @(232, 7)
$script:StepperArrowNext      = @(244, 7)
$script:StepperArrowW         = 6
$script:StepperArrowH         = 9
# Status row (spec.md): dot 11px fixed; normal box (30,120) 218x14 centered,
# checking (long text) box (27,120) 239x14 with ellipsis, dot shifts to x=10.
$script:RowStatusTop          = 120
$script:StatusRowHeight       = 14
$script:StatusDotSize         = 11
# Status row: one fixed layout for every state - the indicator never moves and
# the text starts right after it, left-aligned (ellipsis on overflow).
$script:StatusDotX            = 10
$script:StatusDotTop          = 121
$script:StatusBox             = @(24, 120, 244, 14)
# Network halves (spec.md): (30,137)/(144,137), 104x14, centered per half.
$script:RowNetworkTop         = 137
$script:RowNetworkHeight      = 14
$script:NetworkHalf1Left      = 30
$script:NetworkHalf2Left      = 144
$script:NetworkHalfWidth      = 104
# Footer: schedule field (10,158) 152x22; two small version lines occupy
# x=166..268 without touching the schedule bubble.
$script:RowFooterTop          = 158
$script:ComboScheduleHeight   = 22
$script:ComboScheduleWidth    = 152
$script:VersionRightEdge      = 268
$script:VersionLeft           = 166
$script:VersionTop            = 157
$script:VersionRowHeight      = 24
$script:BalloonTimeoutMs      = 5000
$script:SingleInstanceMutex   = 'Global\ZapretAutopilot.Tray.SingleInstance'
# Brand fox (design/icon-fox-transparent, shipped as assets\tray-fox.png):
# drawn as the tray icon base with the state glyph reduced to a corner badge.
$script:TrayFoxRelativePath   = 'assets\tray-fox.png'
$script:trayFoxBase           = $null
# Header logo (design v2): the same fox artwork shipped separately at 48x48
# (assets\logo-fox.png), drawn in the header at 12x12 (10,7).
$script:LogoFoxRelativePath   = 'assets\logo-fox.png'
$script:logoFoxBase           = $null
$script:GeometryQuietTicks    = 1  # widget Move quiet for this many ticks before persisting
# Strategy-test cadence (settings.testSchedule): combo mapping and whitelist.
# Persisted manual state only - the engine reads the value at each start, the
# tray never sends a command for it.
$script:TestScheduleValues   = @('onboot', 'every3days', 'weekly', 'monthly')
$script:TestScheduleDefault  = 'onboot'
$script:TestScheduleLabels   = [ordered]@{
    onboot     = 'On Windows startup'
    every3days = 'Every 2-3 days'
    weekly     = 'Weekly'
    monthly    = 'Monthly'
}

# ---------------------------------------------------------------------------
# Palette - approved widget mockup (zl-mockup-v1 layout, v3 controls)
# ---------------------------------------------------------------------------
# Palette per design/spec.md (Kimi Design draft zapret-lazy-widget).
$script:ColorCardBg     = [System.Drawing.Color]::FromArgb(0x13, 0x14, 0x17)
$script:ColorHeaderBg   = [System.Drawing.Color]::FromArgb(0x19, 0x1A, 0x1E)
$script:ColorBorder     = [System.Drawing.Color]::FromArgb(0x21, 0x22, 0x26)
$script:ColorComboBg    = [System.Drawing.Color]::FromArgb(0x21, 0x22, 0x27)
$script:ColorFieldBord  = [System.Drawing.Color]::FromArgb(0x2E, 0x2F, 0x36)
$script:ColorText       = [System.Drawing.Color]::FromArgb(0xED, 0xEF, 0xF3)
$script:ColorComboText  = [System.Drawing.Color]::FromArgb(0xE8, 0xE9, 0xEE)
$script:ColorMuted      = [System.Drawing.Color]::FromArgb(0x8B, 0x8C, 0x96)
$script:ColorButtonIdle = [System.Drawing.Color]::FromArgb(0x9A, 0x9B, 0xA4)
$script:ColorAccent     = [System.Drawing.Color]::FromArgb(0xE8, 0x72, 0x0C)
$script:ColorAccentHi   = [System.Drawing.Color]::FromArgb(0xFF, 0x9A, 0x3C)
$script:ColorHover      = [System.Drawing.Color]::FromArgb(0x35, 0x36, 0x3E)
$script:ColorOk         = [System.Drawing.Color]::FromArgb(0x6F, 0xCF, 0x7A)
$script:ColorStopped    = [System.Drawing.Color]::FromArgb(0x9A, 0x6A, 0x3C)
$script:ColorError      = [System.Drawing.Color]::FromArgb(0xD9, 0x53, 0x4F)

# ---------------------------------------------------------------------------
# Shared mutable state (script scope so event handlers can reach it)
# ---------------------------------------------------------------------------
$script:notifyIcon         = $null
$script:trayStateIcon      = $null
$script:contextMenu        = $null
$script:widgetMenu         = $null
$script:menuToggle         = $null
$script:widgetMenuToggle   = $null
$script:appContext         = $null
$script:widgetForm         = $null
$script:pnlHeader          = $null
$script:lblTitle           = $null
$script:btnMenu            = $null
$script:btnClose           = $null
$script:pnlPin             = $null
$script:widgetPinned       = $false
$script:lblStrategyCaption = $null
$script:stepStrategy       = $null
$script:stepGame           = $null
$script:stepIpset          = $null
$script:pnlDot             = $null
$script:stateGlyphMode     = 'stop'   # initial sentinel; spin | run | paused | error
$script:stateGlyphColor    = $null
$script:spinStep          = 0
$script:spinTimer          = $null
$script:brushStateGlyph    = $null
$script:penStateGlyph      = $null
$script:penStateHi         = $null
$script:lblStatus          = $null
$script:ddSchedule        = $null
$script:lblVersion         = $null
$script:appVersion         = ''
$script:networkRowLabels   = New-Object System.Collections.Generic.List[object]
$script:networkHalfPanels   = @($null, $null)
$script:balloonPrimed      = $false
$script:lastActiveStrategy = ''
$script:lastPhase          = ''
$script:lastStatus         = $null
$script:comboSuppress      = $false
$script:pendingStrategy    = ''
$script:pendingGame        = ''
$script:pendingIpset       = ''
$script:pendingDeadline    = $null
$script:scheduleSuppress   = $false
$script:geometryApplied    = $false
$script:geometryDirty      = $false
$script:geometryQuiet      = 0
$script:pendingPoint       = $null
$script:dragOffset         = $null
$script:uiTimer            = $null
$script:singleMutex        = $null
$script:trayLockPath       = $null
$script:fontTitle          = $null
$script:fontCaption        = $null
$script:fontCombo          = $null
$script:fontStatus         = $null
$script:fontNetwork        = $null
$script:fontNetworkSemi    = $null
$script:fontFooter         = $null
$script:fontMenuButton     = $null
$script:fontCloseButton    = $null
$script:brushAccent        = $null
$script:brushComboRow      = $null
$script:penBorder          = $null
$script:penAccent          = $null
# Per-boot auto-hide (see docs/CONVENTIONS.md "settings.json"): armed waits for
# the check to finish, countdown keeps the final message up for the delay,
# done never fires again this session. A manual toggle sets autoHideCancelled.
$script:autoHideEnabled   = $true
$script:autoHideDelaySec  = 300
$script:autoHideState     = 'armed'
$script:autoHideDeadline  = $null
$script:autoHideCancelled = $false

function Get-JsonProp {
    # StrictMode-safe read on ConvertFrom-Json objects and hashtables ($null when missing).
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $null }
    return $prop.Value
}

function Get-TrayStateDir {
    $dir = Join-Path (Get-Root) 'state'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    return $dir
}

function Get-UtcIso8601 {
    return (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
}

function Write-TrayCommand {
    # Sole writer of state/commands.json; engine reads, executes, moves to
    # commands.processed.json. Atomic: temp file + move.
    param([Parameter(Mandatory = $true)]$Command)
    try {
        $dir = Get-TrayStateDir
        $path = Join-Path $dir 'commands.json'
        $tmp = "$path.tmp"
        ($Command | ConvertTo-Json -Depth 5) | Set-Content -Path $tmp -Encoding UTF8
        Move-Item -Force $tmp $path
        $strategyPart = ''
        $strategy = Get-JsonProp $Command 'strategy'
        if (-not [string]::IsNullOrWhiteSpace([string]$strategy)) { $strategyPart = " strategy=$strategy" }
        Write-Log 'Tray' 'CommandSent' ("command=" + (Get-JsonProp $Command 'command') + $strategyPart)
    } catch {
        Write-Log 'Tray' 'CommandSendFailed' "error=$($_.Exception.Message)"
    }
}

function Send-SwitchCommand {
    param([Parameter(Mandatory = $true)][string]$StrategyName)
    Write-TrayCommand ([ordered]@{ command = 'switch'; strategy = $StrategyName; issuedAt = Get-UtcIso8601 })
}

function Send-RetestCommand {
    Write-TrayCommand ([ordered]@{ command = 'retest'; issuedAt = Get-UtcIso8601 })
}

function Send-ShutdownCommand {
    Write-TrayCommand ([ordered]@{ command = 'shutdown'; issuedAt = Get-UtcIso8601 })
}

function Send-OptionCommand {
    # Engine-side 'setoption' (src/ServiceManager.psm1): persists the new value
    # through Save-Config and reapplies the active stock .bat without a full
    # strategy test.
    param(
        [Parameter(Mandatory = $true)][string]$Option,
        [Parameter(Mandatory = $true)][string]$Value
    )
    Write-TrayCommand ([ordered]@{ command = 'setoption'; option = $Option; value = $Value; issuedAt = Get-UtcIso8601 })
}

function Get-TestScheduleValue {
    # Current settings.testSchedule via Get-Config; a missing property (older
    # engine build) or an unknown hand-edited value falls back to 'onboot'.
    try {
        $value = [string](Get-JsonProp (Get-Config) 'testSchedule')
        if ($script:TestScheduleValues -contains $value) { return $value }
        return $script:TestScheduleDefault
    } catch {
        Write-Log 'Tray' 'ScheduleReadFailed' "error=$($_.Exception.Message)"
        return $script:TestScheduleDefault
    }
}

function Set-TestScheduleValue {
    # Persist the strategy-test cadence through Save-Config (the only writer of
    # settings.json). Never writes state/commands.json: the engine picks the
    # new value up at its next start.
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($script:TestScheduleValues -notcontains $Value) {
        Write-Log 'Tray' 'ScheduleRejected' "value=$Value"
        return
    }
    try {
        $cfg = Get-Config
        $cfg | Add-Member -MemberType NoteProperty -Name 'testSchedule' -Value $Value -Force
        Save-Config $cfg
        Write-Log 'Tray' 'ScheduleChanged' "value=$Value"
    } catch {
        Write-Log 'Tray' 'ScheduleSaveFailed' "value=$Value error=$($_.Exception.Message)"
    }
}

function Ensure-WidgetSection {
    # StrictMode-safe: missing widget props are added before assignment.
    param($Cfg)
    if ($null -eq (Get-JsonProp $Cfg 'widget')) {
        $Cfg | Add-Member -MemberType NoteProperty -Name widget -Value ([pscustomobject]@{
            x = $null; y = $null; visible = $true
            autoHideAfterBoot = $true; autoHideDelaySec = 300; pinned = $false
        })
    }
    $widget = $Cfg.widget
    if ($null -eq $widget.PSObject.Properties['x']) { $widget | Add-Member -MemberType NoteProperty -Name x -Value $null }
    if ($null -eq $widget.PSObject.Properties['y']) { $widget | Add-Member -MemberType NoteProperty -Name y -Value $null }
    if ($null -eq $widget.PSObject.Properties['visible']) { $widget | Add-Member -MemberType NoteProperty -Name visible -Value $true }
    if ($null -eq $widget.PSObject.Properties['autoHideAfterBoot']) { $widget | Add-Member -MemberType NoteProperty -Name autoHideAfterBoot -Value $true }
    if ($null -eq $widget.PSObject.Properties['autoHideDelaySec']) { $widget | Add-Member -MemberType NoteProperty -Name autoHideDelaySec -Value 300 }
    if ($null -eq $widget.PSObject.Properties['pinned']) { $widget | Add-Member -MemberType NoteProperty -Name pinned -Value $false }
}

function Save-WidgetPrefs {
    # Persist widget geometry + visibility through Save-Config (only writer of settings.json).
    param([bool]$Visible)
    try {
        $cfg = Get-Config
        Ensure-WidgetSection $cfg
        $cfg.widget.x = $script:widgetForm.Location.X
        $cfg.widget.y = $script:widgetForm.Location.Y
        $cfg.widget.visible = $Visible
        $cfg.widget.pinned = $script:widgetPinned
        Save-Config $cfg
        Write-Log 'Tray' 'WidgetMoved' "x=$($cfg.widget.x) y=$($cfg.widget.y) visible=$Visible pinned=$($cfg.widget.pinned)"
    } catch {
        Write-Log 'Tray' 'WidgetPrefsSaveFailed' "error=$($_.Exception.Message)"
    }
}

function New-UIFont {
    # Segoe UI with a Semibold variant; falls back to regular Segoe UI Bold when
    # the Semibold family is absent (older Windows builds).
    param(
        [Parameter(Mandatory = $true)][double]$Size,
        [System.Drawing.FontStyle]$Style = [System.Drawing.FontStyle]::Regular,
        [switch]$SemiBold
    )
    if ($SemiBold) {
        try {
            return New-Object System.Drawing.Font('Segoe UI Semibold', $Size, $Style)
        } catch {
            return New-Object System.Drawing.Font('Segoe UI', $Size, ([System.Drawing.FontStyle]::Bold -bor $Style))
        }
    }
    return New-Object System.Drawing.Font('Segoe UI', $Size, $Style)
}

function New-RoundedRectPath {
    # Anti-aliased rounded-rectangle outline used for the card border (Paint),
    # the window Region (transparent corners, no native title bar), and the
    # custom dropdown fields/popups.
    param(
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [int]$Radius = 0
    )
    if ($Radius -le 0) { $Radius = $script:WidgetCornerRadius }
    $d = $Radius * 2
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    [void]$path.AddArc(0, 0, $d, $d, 180, 90)
    [void]$path.AddArc(($Width - $d - 1), 0, $d, $d, 270, 90)
    [void]$path.AddArc(($Width - $d - 1), ($Height - $d - 1), $d, $d, 0, 90)
    [void]$path.AddArc(0, ($Height - $d - 1), $d, $d, 90, 90)
    [void]$path.CloseFigure()
    return $path
}

function Set-LabelSmooth {
    # GDI+ anti-aliased text rendering (softer glyphs than classic GDI).
    param([Parameter(Mandatory = $true)]$Label)
    $Label.UseCompatibleTextRendering = $false
}

function New-ValueLabel {
    # Value label: plain GDI+ anti-aliased Consolas text.
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][int]$Left,
        [Parameter(Mandatory = $true)][int]$Top,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        $Color,
        $Back = $null
    )
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.SetBounds($Left, $Top, $Width, $Height)
    $lbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $lbl.Font = $script:fontCombo
    $lbl.ForeColor = $Color
    if ($null -ne $Back) { $lbl.BackColor = $Back }
    Set-LabelSmooth $lbl
    [void]$Parent.Controls.Add($lbl)
    return $lbl
}

function Set-ZlText {
    param($Ctrl, [AllowNull()][string]$Text)
    $Ctrl.Text = $Text
}

function Set-ZlForeColor {
    param($Ctrl, $Color)
    $Ctrl.ForeColor = $Color
}

function Remove-ZlLabel {
    param($Ctrl)
    $Ctrl.Dispose()
}

# ---------------------------------------------------------------------------
# Custom dark dropdown: a rounded field opens a rounded dark popup, so the
# open list matches the widget style (a native ComboBox popup renders light
# with square corners). State bag fields: Items, SelectedIndex, Enabled,
# OnSelect (scriptblock invoked with the picked string), Hover, Label, Panel.
# ---------------------------------------------------------------------------
$script:openDropdownPopup = $null

function New-ZlDropdown {
    # Closed dropdown field per design: 258x22, radius 5, fill #212227,
    # border #2E2F36 (#2E2F36 at 50% and chevron at 40% when disabled), accent
    # border on hover. Chevron = design/icon-chevron.svg (stroke 1.2, round).
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][int]$Left,
        [Parameter(Mandatory = $true)][int]$Top,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds($Left, $Top, $Width, $Height)
    $panel.BackColor = $script:ColorCardBg
    $panel.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic).SetValue($panel, $true, $null)
    $state = @{
        Items = New-Object System.Collections.Generic.List[string]
        SelectedIndex = -1
        Enabled = $true
        OnSelect = $null
        Hover = $false
        Panel = $panel
        Label = $null
    }
    $panel.Tag = $state
    $panel.add_Paint({
        param($sender, $e)
        $s = $sender.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $path = New-RoundedRectPath $sender.Width $sender.Height 5
        $fillBrush = New-Object System.Drawing.SolidBrush $script:ColorComboBg
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()
        $borderColor = $script:ColorFieldBord
        if ($s.Enabled -and $s.Hover) { $borderColor = $script:ColorAccent }
        if (-not $s.Enabled) { $borderColor = [System.Drawing.Color]::FromArgb(0x80, $script:ColorFieldBord) }
        $pen = New-Object System.Drawing.Pen $borderColor
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
        # chevron (design/icon-chevron.svg: M1 1 L5 5 L9 1, stroke 1.2 round)
        $chevColor = $script:ColorButtonIdle
        if (-not $s.Enabled) { $chevColor = [System.Drawing.Color]::FromArgb(0x66, $script:ColorButtonIdle) }
        $penChev = New-Object System.Drawing.Pen $chevColor, 1.2
        $penChev.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $penChev.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $chevPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $bx = $sender.Width - 16
        $by = [int](($sender.Height - 6) / 2)
        [void]$chevPath.AddLine(($bx + 1), ($by + 1), ($bx + 5), ($by + 5))
        [void]$chevPath.AddLine(($bx + 5), ($by + 5), ($bx + 9), ($by + 1))
        $g.DrawPath($penChev, $chevPath)
        $penChev.Dispose()
        $chevPath.Dispose()
    })
    # text pad 6: Consolas 9 is wider than the design font, so the spec's 8px
    # inset becomes 6 and the label takes the full field width; if the text
    # still does not fit, auto-fit drops one point (design wants one size, but
    # a clipped label is worse than a 1pt step-down).
    $lbl = New-ValueLabel -Parent $panel -Left 6 -Top 0 -Width ($Width - 8) -Height $Height -Color $script:ColorComboText -Back $script:ColorComboBg
    try {
        $needW = [System.Windows.Forms.TextRenderer]::MeasureText('On Windows startup', $script:fontCombo).Width
        if ($needW -gt ($Width - 14) -and $lbl -is [System.Windows.Forms.Label]) {
            $lbl.Font = New-Object System.Drawing.Font('Consolas', 8)
        }
    } catch { }
    $state.Label = $lbl
    # Clicks land on the child label over most of the field, so the open and
    # hover handlers are attached to the label as well as the panel.
    $panel.add_MouseEnter({ $this.Tag.Hover = $true; [void]$this.Invalidate() })
    $panel.add_MouseLeave({ $this.Tag.Hover = $false; [void]$this.Invalidate() })
    $panel.add_Click({ Show-ZlDropdownPopup $this.Tag $this })
    if ($lbl -is [System.Windows.Forms.Label]) {
        $lbl.add_MouseEnter({ $this.Parent.Tag.Hover = $true; [void]$this.Parent.Invalidate() })
        $lbl.add_MouseLeave({ $this.Parent.Tag.Hover = $false; [void]$this.Parent.Invalidate() })
        $lbl.add_Click({ Show-ZlDropdownPopup $this.Parent.Tag $this.Parent })
    }
    [void]$Parent.Controls.Add($panel)
    return $state
}

function Set-ZlDropdownItems {
    param($State, [AllowEmptyCollection()][string[]]$Items)
    $State.Items.Clear()
    foreach ($item in $Items) { [void]$State.Items.Add([string]$item) }
    if ($State.Items.Count -gt 0) { Set-ZlDropdownSelection $State 0 }
}

function Set-ZlDropdownSelection {
    param($State, [Parameter(Mandatory = $true)][int]$Index)
    if ($Index -ge 0 -and $Index -lt $State.Items.Count) {
        $State.SelectedIndex = $Index
        Set-ZlText $State.Label $State.Items[$Index]
    }
}

function Set-ZlDropdownEnabled {
    param($State, [Parameter(Mandatory = $true)][bool]$Enabled)
    $State.Enabled = $Enabled
    Set-ZlForeColor $State.Label (& { if ($Enabled) { $script:ColorComboText } else { $script:ColorButtonIdle } })
    [void]$State.Panel.Invalidate()
}

function Show-ZlDropdownPopup {
    param(
        [Parameter(Mandatory = $true)]$State,
        [Parameter(Mandatory = $true)]$OwnerPanel
    )
    if (-not $State.Enabled) { return }
    if ($State.Items.Count -eq 0) { return }
    if ($null -ne $script:openDropdownPopup) {
        try { $script:openDropdownPopup.Close() } catch { }
        $script:openDropdownPopup = $null
    }
    $itemH = 22
    $pad = 4
    $popupW = $OwnerPanel.Width
    $popupH = [Math]::Min(($State.Items.Count * $itemH) + (2 * $pad) + 2, 240)
    $popup = New-Object System.Windows.Forms.Form
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.ShowInTaskbar = $false
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.BackColor = $script:ColorComboBg
    $popup.ClientSize = New-Object System.Drawing.Size($popupW, $popupH)
    $popup.Location = $OwnerPanel.PointToScreen((New-Object System.Drawing.Point(0, ($OwnerPanel.Height + 2))))
    $regionPath = New-RoundedRectPath $popupW $popupH 6
    $popup.Region = New-Object System.Drawing.Region $regionPath
    $regionPath.Dispose()
    $popup.add_Paint({
        param($sender, $e)
        $path = New-RoundedRectPath $sender.ClientSize.Width $sender.ClientSize.Height 6
        $pen = New-Object System.Drawing.Pen $script:ColorFieldBord
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
    })
    $list = New-Object System.Windows.Forms.ListBox
    $list.SetBounds(1, 1, ($popupW - 2), ($popupH - 2))
    $list.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $list.IntegralHeight = $false
    $list.BackColor = $script:ColorComboBg
    $list.ForeColor = $script:ColorComboText
    $list.Font = $script:fontCombo
    $list.ItemHeight = $itemH
    $list.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
    foreach ($item in $State.Items) { [void]$list.Items.Add($item) }
    $list.SelectedIndex = $State.SelectedIndex
    $list.Tag = @{ Hover = -1; ItemH = $itemH }
    $list.add_DrawItem({
        param($sender, $e)
        if ($e.Index -lt 0) { return }
        $g = $e.Graphics
        $bounds = $e.Bounds
        $tag = $sender.Tag
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $script:ColorComboBg), $bounds)
        if ($e.Index -eq $tag.Hover) {
            $row = New-Object System.Drawing.Rectangle(($bounds.X + 2), ($bounds.Y + 1), ($bounds.Width - 4), ($tag.ItemH - 2))
            $rowPath = New-RoundedRectPath $row.Width $row.Height 4
            $matrix = New-Object System.Drawing.Drawing2D.Matrix
            $matrix.Translate([single]$row.X, [single]$row.Y)
            $rowPath.Transform($matrix)
            $g.FillPath((New-Object System.Drawing.SolidBrush $script:ColorHover), $rowPath)
            $rowPath.Dispose()
            $matrix.Dispose()
        }
        if (($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) {
            # active item: 1px accent inside stroke, no fill (design)
            $rect = New-Object System.Drawing.Rectangle(($bounds.X + 2), ($bounds.Y + 1), ($bounds.Width - 5), ($tag.ItemH - 3))
            $g.DrawRectangle($script:penAccent, $rect)
        }
        $txtRect = New-Object System.Drawing.Rectangle(($bounds.X + 10), $bounds.Y, ($bounds.Width - 14), $tag.ItemH)
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                  [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                  [System.Windows.Forms.TextFormatFlags]::SingleLine
        [void][System.Windows.Forms.TextRenderer]::DrawText($g, [string]$sender.Items[$e.Index], $sender.Font, $txtRect, $sender.ForeColor, $flags)
    })
    $list.add_MouseMove({
        param($sender, $e)
        $idx = $sender.IndexFromPoint($e.Location)
        if ($idx -ne $sender.Tag.Hover) { $sender.Tag.Hover = $idx; [void]$sender.Invalidate() }
    })
    $commit = {
        param($idx)
        if ($idx -ge 0 -and $idx -lt $State.Items.Count) {
            $State.SelectedIndex = $idx
            Set-ZlText $State.Label $State.Items[$idx]
            if ($null -ne $State.OnSelect) { & $State.OnSelect $State.Items[$idx] }
        }
        try { $popup.Close() } catch { }
    }.GetNewClosure()
    $list.add_Click({ & $commit $this.SelectedIndex }.GetNewClosure())
    $list.add_KeyDown({
        param($sender, $e)
        if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { & $commit $sender.SelectedIndex; $e.SuppressKeyPress = $true }
        elseif ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { try { $popup.Close() } catch { }; $e.SuppressKeyPress = $true }
    }.GetNewClosure())
    $popup.add_Deactivate({ try { $this.Close() } catch { } })
    [void]$popup.Controls.Add($list)
    $script:openDropdownPopup = $popup
    $popup.add_FormClosed({ if ($script:openDropdownPopup -eq $this) { $script:openDropdownPopup = $null } })
    $ownerForm = $OwnerPanel.FindForm()
    if ($null -ne $ownerForm) { [void]$popup.Show($ownerForm) } else { [void]$popup.Show() }
    $list.Focus()
}

# ---------------------------------------------------------------------------
# Custom dark stepper (design v2): a rounded field with '<' '>' arrows instead
# of a dropdown popup — used by all three setting fields (strat, game filter,
# ipset list). Values cycle with a short horizontal slide animation.
# State bag fields: Items, SelectedIndex, Enabled, OnStep (scriptblock invoked
# with the new string), Hover ('' | 'prev' | 'next'), Panel, Caption, Value,
# AnimOld, AnimDir, AnimStep, AnimTimer.
# ---------------------------------------------------------------------------
function Draw-StepperArrow {
    # '<' / '>' chevron pair, stroke 1.2 round cap, inside a 6x9 box at (X,Y).
    param($Graphics, [int]$X, [int]$Y, [int]$Dir, $Color)
    $pen = New-Object System.Drawing.Pen $Color, 1.2
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    if ($Dir -lt 0) {
        [void]$path.AddLine(($X + 4.5), ($Y + 0.5), ($X + 1.5), ($Y + 4.0))
        [void]$path.AddLine(($X + 1.5), ($Y + 4.0), ($X + 4.5), ($Y + 7.5))
    } else {
        [void]$path.AddLine(($X + 1.5), ($Y + 0.5), ($X + 4.5), ($Y + 4.0))
        [void]$path.AddLine(($X + 4.5), ($Y + 4.0), ($X + 1.5), ($Y + 7.5))
    }
    $Graphics.DrawPath($pen, $path)
    $pen.Dispose()
    $path.Dispose()
}

function Get-StepperDisplayValue {
    param([string]$Caption, [string]$Value)
    if ($Caption -eq 'strat') {
        $name = [IO.Path]::GetFileNameWithoutExtension($Value)
        if ($name -match '^general\s*\((?<short>.+)\)$') { return $Matches.short }
        if ($name -eq 'general') { return 'base' }
        return ($name -replace '^general\s*', '')
    }
    if ($Caption -eq 'game filter' -and $Value -eq 'all') { return 'tcp and udp' }
    return $Value
}

function Start-StepperAnim {
    # Fast one-way transition: old exits, then new enters from the pressed side.
    param($State, [string]$OldValue, [int]$Dir)
    try {
        if ($null -ne $State.AnimTimer) { $State.AnimTimer.Stop() }
        $State.AnimOld = $OldValue
        $State.AnimDir = $Dir
        $State.AnimStep = 0
        if ($null -eq $State.AnimTimer) {
            $t = New-Object System.Windows.Forms.Timer
            $t.Interval = 12
            $t.Tag = $State
            $t.add_Tick({
                $s = $this.Tag
                if ($null -eq $s) { $this.Stop(); return }
                $s.AnimStep = [int]$s.AnimStep + 1
                if ([int]$s.AnimStep -ge 8) { $this.Stop(); $s.AnimOld = '' }
                [void]$s.Panel.Invalidate()
            })
            $State.AnimTimer = $t
        }
        $State.AnimTimer.Start()
    } catch { }
}

function New-ZlStepper {
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][int]$Left,
        [Parameter(Mandatory = $true)][int]$Top,
        [Parameter(Mandatory = $true)][int]$Width,
        [Parameter(Mandatory = $true)][int]$Height,
        [Parameter(Mandatory = $true)][string]$Caption
    )
    $panel = New-Object System.Windows.Forms.Panel
    $panel.SetBounds($Left, $Top, $Width, $Height)
    $panel.BackColor = $script:ColorCardBg
    $panel.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic).SetValue($panel, $true, $null)
    $state = @{
        Items = New-Object System.Collections.Generic.List[string]
        SelectedIndex = -1
        Enabled = $true
        OnStep = $null
        Hover = ''
        Panel = $panel
        Caption = $Caption
        Value = ''
        AnimOld = ''
        AnimDir = 0
        AnimStep = 0
        AnimTimer = $null
    }
    $panel.Tag = $state
    $panel.add_Paint({
        param($sender, $e)
        $s = $sender.Tag
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $path = New-RoundedRectPath $sender.Width $sender.Height 5
        $fillBrush = New-Object System.Drawing.SolidBrush $script:ColorComboBg
        $g.FillPath($fillBrush, $path)
        $fillBrush.Dispose()
        $borderColor = $script:ColorFieldBord
        if ($s.Enabled -and ([string]$s.Hover -ne '')) { $borderColor = $script:ColorAccent }
        if (-not $s.Enabled) { $borderColor = [System.Drawing.Color]::FromArgb(0x80, $script:ColorFieldBord) }
        $pen = New-Object System.Drawing.Pen $borderColor
        $g.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
        # arrows '<' '>' (design v2): 6x9 at field-relative (232,7)/(244,7)
        $arrowColor = $script:ColorButtonIdle
        if (-not $s.Enabled) { $arrowColor = [System.Drawing.Color]::FromArgb(0x66, $script:ColorButtonIdle) }
        $prevColor = $arrowColor
        $nextColor = $arrowColor
        if ($s.Enabled) {
            if ([string]$s.Hover -eq 'prev') { $prevColor = $script:ColorAccent }
            if ([string]$s.Hover -eq 'next') { $nextColor = $script:ColorAccent }
        }
        Draw-StepperArrow $g $script:StepperArrowPrev[0] $script:StepperArrowPrev[1] -1 $prevColor
        Draw-StepperArrow $g $script:StepperArrowNext[0] $script:StepperArrowNext[1] 1 $nextColor
        # text: dim caption + white value, 8px inset; value area stops before
        # the arrows. While AnimOld is set, old and new values cross-slide.
        $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                  [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                  [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                  [System.Windows.Forms.TextFormatFlags]::NoPrefix
        $textArea = New-Object System.Drawing.Rectangle(8, 0, ($script:StepperArrowPrev[0] - 10), $sender.Height)
        $capW = 0
        if (-not [string]::IsNullOrEmpty([string]$s.Caption)) {
            $capSize = [System.Windows.Forms.TextRenderer]::MeasureText(([string]$s.Caption + ' '), $script:fontCombo, (New-Object System.Drawing.Size(0, 0)), $flags)
            $capW = $capSize.Width
            $capRect = New-Object System.Drawing.Rectangle($textArea.X, $textArea.Y, $capW, $textArea.Height)
            [void][System.Windows.Forms.TextRenderer]::DrawText($g, ([string]$s.Caption + ' '), $script:fontCombo, $capRect, $script:ColorMuted, $flags)
        }
        $valColor = $script:ColorComboText
        if (-not $s.Enabled) { $valColor = $script:ColorButtonIdle }
        $valX = $textArea.X + $capW
        $valW = ($textArea.X + $textArea.Width) - $valX
        if ($valW -gt 0) {
            $clipRect = New-Object System.Drawing.Rectangle($valX, $textArea.Y, $valW, $textArea.Height)
            $oldVal = Get-StepperDisplayValue $s.Caption ([string]$s.AnimOld)
            $newVal = Get-StepperDisplayValue $s.Caption ([string]$s.Value)
            $bubbleClip = New-RoundedRectPath $sender.Width $sender.Height 5
            $g.SetClip($clipRect)
            $g.SetClip($bubbleClip, [System.Drawing.Drawing2D.CombineMode]::Intersect)
            if (-not [string]::IsNullOrEmpty($oldVal) -and $oldVal -ne $newVal) {
                $step = [int]$s.AnimStep
                $dir = [int]$s.AnimDir
                $travel = $valW + 20
                if ($step -lt 4) {
                    $progress = $step / 4.0
                    $dx = -$dir * [int]($progress * $travel)
                    $alpha = 255 - [int]($progress * 200)
                    $color = [System.Drawing.Color]::FromArgb($alpha, $valColor)
                    $rect = New-Object System.Drawing.Rectangle(($valX + $dx), $textArea.Y, $valW, $textArea.Height)
                    [void][System.Windows.Forms.TextRenderer]::DrawText($g, $oldVal, $script:fontCombo, $rect, $color, $flags)
                } else {
                    $progress = ($step - 4) / 4.0
                    $dx = $dir * [int]((1.0 - $progress) * $travel)
                    $alpha = 80 + [int]($progress * 175)
                    $color = [System.Drawing.Color]::FromArgb($alpha, $valColor)
                    $rect = New-Object System.Drawing.Rectangle(($valX + $dx), $textArea.Y, $valW, $textArea.Height)
                    [void][System.Windows.Forms.TextRenderer]::DrawText($g, $newVal, $script:fontCombo, $rect, $color, $flags)
                }
            } else {
                $valRect = New-Object System.Drawing.Rectangle($valX, $textArea.Y, $valW, $textArea.Height)
                [void][System.Windows.Forms.TextRenderer]::DrawText($g, $newVal, $script:fontCombo, $valRect, $valColor, $flags)
            }
            $g.ResetClip()
            $bubbleClip.Dispose()
        }
    })
    $panel.add_MouseMove({
        param($sender, $e)
        $s = $sender.Tag
        $h = ''
        if ($s.Enabled) {
            $prevHit = New-Object System.Drawing.Rectangle(($script:StepperArrowPrev[0] - 2), ($script:StepperArrowPrev[1] - 2), ($script:StepperArrowW + 4), ($script:StepperArrowH + 4))
            $nextHit = New-Object System.Drawing.Rectangle(($script:StepperArrowNext[0] - 2), ($script:StepperArrowNext[1] - 2), ($script:StepperArrowW + 4), ($script:StepperArrowH + 4))
            if ($prevHit.Contains($e.Location)) { $h = 'prev' }
            elseif ($nextHit.Contains($e.Location)) { $h = 'next' }
        }
        if ($h -ne [string]$s.Hover) { $s.Hover = $h; [void]$sender.Invalidate() }
    })
    $panel.add_MouseLeave({ $this.Tag.Hover = ''; [void]$this.Invalidate() })
    $panel.add_MouseClick({
        param($sender, $e)
        $s = $sender.Tag
        if (-not $s.Enabled) { return }
        $prevHit = New-Object System.Drawing.Rectangle(($script:StepperArrowPrev[0] - 2), ($script:StepperArrowPrev[1] - 2), ($script:StepperArrowW + 4), ($script:StepperArrowH + 4))
        $nextHit = New-Object System.Drawing.Rectangle(($script:StepperArrowNext[0] - 2), ($script:StepperArrowNext[1] - 2), ($script:StepperArrowW + 4), ($script:StepperArrowH + 4))
        if ($prevHit.Contains($e.Location)) { Step-ZlStepper $s -1 }
        elseif ($nextHit.Contains($e.Location)) { Step-ZlStepper $s 1 }
    })
    [void]$Parent.Controls.Add($panel)
    return $state
}

function Set-ZlStepperItems {
    param($State, [AllowEmptyCollection()][string[]]$Items)
    $State.Items.Clear()
    foreach ($item in $Items) { [void]$State.Items.Add([string]$item) }
    $State.SelectedIndex = -1
    $State.Value = ''
    if ($State.Items.Count -gt 0) { Set-ZlStepperSelection $State 0 }
    [void]$State.Panel.Invalidate()
}

function Set-ZlStepperSelection {
    # Programmatic selection (engine-driven sync): no animation, no OnStep.
    param($State, [Parameter(Mandatory = $true)][int]$Index)
    if ($Index -ge 0 -and $Index -lt $State.Items.Count) {
        if ($null -ne $State.AnimTimer) { $State.AnimTimer.Stop() }
        $State.AnimOld = ''
        $State.SelectedIndex = $Index
        $State.Value = $State.Items[$Index]
        [void]$State.Panel.Invalidate()
    }
}

function Set-ZlStepperEnabled {
    param($State, [Parameter(Mandatory = $true)][bool]$Enabled)
    $State.Enabled = $Enabled
    if (-not $Enabled) { $State.Hover = '' }
    [void]$State.Panel.Invalidate()
}

function Step-ZlStepper {
    # One step in Dir (-1 prev / +1 next), wrapping around the item list.
    param($State, [int]$Dir)
    if (-not $State.Enabled) { return }
    if ($State.Items.Count -eq 0) { return }
    $idx = 0
    if ($State.SelectedIndex -ge 0) { $idx = ($State.SelectedIndex + $Dir + $State.Items.Count) % $State.Items.Count }
    if ($idx -eq $State.SelectedIndex) { return }
    $old = [string]$State.Value
    $new = $State.Items[$idx]
    $State.SelectedIndex = $idx
    $State.Value = $new
    Start-StepperAnim $State $old $Dir
    [void]$State.Panel.Invalidate()
    if ($null -ne $State.OnStep) { & $State.OnStep $new }
}

# ---------------------------------------------------------------------------
# Header icon buttons and the custom dark menu popup (design/artboard-menu):
# items 24px tall, text pad 12, hover #35363E r4, separator #2E2F36.
# ---------------------------------------------------------------------------
function New-IconButton {
    param(
        [Parameter(Mandatory = $true)]$Parent,
        [Parameter(Mandatory = $true)][int[]]$Bounds,
        [Parameter(Mandatory = $true)][ValidateSet('dots', 'close')][string]$Kind
    )
    $btn = New-Object System.Windows.Forms.Panel
    $btn.SetBounds($Bounds[0], $Bounds[1], $Bounds[2], $Bounds[3])
    $btn.BackColor = $script:ColorHeaderBg
    $btn.Tag = @{ Kind = $Kind; Hover = $false }
    $btn.add_Paint({
        param($sender, $e)
        $tag = $sender.Tag
        $color = $script:ColorButtonIdle
        if ($tag.Hover) { $color = $script:ColorAccent }
        $brush = New-Object System.Drawing.SolidBrush $color
        $pen = New-Object System.Drawing.Pen $color, 1.2
        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            if ($tag.Kind -eq 'dots') {
                # design/icon-dots.svg: three dots r1.2 at cy 2/6/10 of a 10x12 box
                $cx = $sender.Width / 2.0
                $scaleY = $sender.Height / 12.0
                foreach ($cy in @(2, 6, 10)) {
                    $g.FillEllipse($brush, ($cx - 1.2), (($cy * $scaleY) - 1.2), 2.4, 2.4)
                }
            } else {
                # design/icon-close.svg: M2 2 L8 8 / M8 2 L2 8 in a 10x10 box
                $k = $sender.Width / 10.0
                $p1 = New-Object System.Drawing.Point(($k * 2), ($k * 2))
                $p2 = New-Object System.Drawing.Point(($k * 8), ($k * 8))
                $p3 = New-Object System.Drawing.Point(($k * 8), ($k * 2))
                $p4 = New-Object System.Drawing.Point(($k * 2), ($k * 8))
                $g.DrawLine($pen, $p1, $p2)
                $g.DrawLine($pen, $p3, $p4)
            }
        } finally {
            $brush.Dispose()
            $pen.Dispose()
        }
    })
    $btn.add_MouseEnter({ $this.Tag.Hover = $true; [void]$this.Invalidate() })
    $btn.add_MouseLeave({ $this.Tag.Hover = $false; [void]$this.Invalidate() })
    [void]$Parent.Controls.Add($btn)
    return $btn
}

$script:openZlMenu = $null

function Show-ZlMenu {
    # Dark rounded menu popup (replaces the system ContextMenuStrip, which
    # rendered with light-theme artifacts).
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$Owner,
        [Parameter(Mandatory = $true)][array]$Items
    )
    if ($null -ne $script:openZlMenu) {
        try { $script:openZlMenu.Close() } catch { }
        $script:openZlMenu = $null
    }
    $textW = 0
    foreach ($it in $Items) {
        if ($it.ContainsKey('Separator') -and $it['Separator']) { continue }
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText([string]$it['Text'], $script:fontCombo)
        if ($sz.Width -gt $textW) { $textW = $sz.Width }
    }
    $menuW = [Math]::Max(142, $textW + 24)
    $rowH = 24
    $topPad = 6
    $sepH = 9
    $height = $topPad
    foreach ($it in $Items) { if ($it.ContainsKey('Separator') -and $it['Separator']) { $height += $sepH } else { $height += $rowH } }
    $height += 4
    # Flip to stay on screen: at the right edge the popup grows leftward from
    # the button's right edge; at the bottom it opens above the button.
    $workArea = [System.Windows.Forms.SystemInformation]::WorkingArea
    $anchor = [System.Windows.Forms.Cursor]::Position
    if ($null -eq $Owner) {
        $popupX = $anchor.X
        $popupY = $anchor.Y
    } else {
        $btnTopLeft = $Owner.PointToScreen([System.Drawing.Point]::Empty)
        $popupX = $btnTopLeft.X
        $popupY = $btnTopLeft.Y + $Owner.Height
    }
    if (($popupX + $menuW) -gt $workArea.Right) {
        if ($null -eq $Owner) { $popupX = $workArea.Right - $menuW } else { $popupX = $btnTopLeft.X + $Owner.Width - $menuW }
    }
    if (($popupY + $height) -gt $workArea.Bottom) {
        if ($null -eq $Owner) { $popupY = $workArea.Bottom - $height } else { $popupY = $btnTopLeft.Y - $height }
    }
    if ($popupX -lt $workArea.Left) { $popupX = $workArea.Left }
    $popup = New-Object System.Windows.Forms.Form
    $popup.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $popup.ShowInTaskbar = $false
    # Tray overflow is itself topmost; an unowned context menu must be topmost
    # too or Windows leaves it behind the overflow panel.
    $popup.TopMost = ($null -eq $Owner)
    $popup.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $popup.BackColor = $script:ColorComboBg
    $popup.ClientSize = New-Object System.Drawing.Size($menuW, $height)
    $popup.Location = New-Object System.Drawing.Point($popupX, $popupY)
    $regionPath = New-RoundedRectPath $menuW $height 6
    $popup.Region = New-Object System.Drawing.Region $regionPath
    $regionPath.Dispose()
    $popup.add_Paint({
        param($sender, $e)
        $path = New-RoundedRectPath $sender.ClientSize.Width $sender.ClientSize.Height 6
        $pen = New-Object System.Drawing.Pen $script:ColorFieldBord
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.DrawPath($pen, $path)
        $pen.Dispose()
        $path.Dispose()
    })
    $y = $topPad
    foreach ($it in $Items) {
        if ($it.ContainsKey('Separator') -and $it['Separator']) {
            $sep = New-Object System.Windows.Forms.Panel
            $sep.SetBounds(6, ($y + 4), ($menuW - 12), 1)
            $sep.BackColor = $script:ColorFieldBord
            [void]$popup.Controls.Add($sep)
            $y += $sepH
            continue
        }
        $item = New-Object System.Windows.Forms.Panel
        $item.SetBounds(2, $y, ($menuW - 4), $rowH)
        $item.Tag = @{ Action = $it['Action']; Hover = $false; Text = [string]$it['Text'] }
        $item.add_Paint({
            param($sender, $e)
            $tag = $sender.Tag
            $g = $e.Graphics
            $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
            if ($tag.Hover) {
                $rowPath = New-RoundedRectPath $sender.Width $sender.Height 4
                $g.FillPath((New-Object System.Drawing.SolidBrush $script:ColorHover), $rowPath)
                $rowPath.Dispose()
            }
            $rect = New-Object System.Drawing.Rectangle(12, 0, ($sender.Width - 16), $sender.Height)
            $flags = [System.Windows.Forms.TextFormatFlags]::Left -bor `
                      [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor `
                      [System.Windows.Forms.TextFormatFlags]::SingleLine
            [void][System.Windows.Forms.TextRenderer]::DrawText($g, $tag.Text, $script:fontCombo, $rect, $script:ColorComboText, $flags)
        })
        $item.add_MouseEnter({ $this.Tag.Hover = $true; [void]$this.Invalidate() })
        $item.add_MouseLeave({ $this.Tag.Hover = $false; [void]$this.Invalidate() })
        $item.add_Click({
            $act = $this.Tag.Action
            try { $script:openZlMenu.Close() } catch { }
            if ($null -ne $act) { & $act }
        })
        [void]$popup.Controls.Add($item)
        $y += $rowH
    }
    $popup.add_Deactivate({ try { $this.Close() } catch { } })
    $popup.add_KeyDown({ param($sender, $e) if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $sender.Close() } })
    $script:openZlMenu = $popup
    $popup.add_FormClosed({ if ($script:openZlMenu -eq $this) { $script:openZlMenu = $null } })
    [void]$popup.Show()
    $popup.Activate()
}

function Register-DragMove {
    # Left-drag on the header moves the borderless form; the form Move event
    # feeds the existing geometry persistence (quiet-tick Save-WidgetPrefs).
    # Plain scriptblocks on purpose: GetNewClosure handlers run in a dynamic
    # module scope where $script: writes would land in the wrong scope.
    param([Parameter(Mandatory = $true)]$Control)
    $Control.add_MouseDown({
        param($sender, $e)
        if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }
        if ($script:widgetPinned) { $script:dragOffset = $null; return }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $origin = $script:widgetForm.PointToScreen([System.Drawing.Point]::Empty)
        $script:dragOffset = New-Object System.Drawing.Point(($cursor.X - $origin.X), ($cursor.Y - $origin.Y))
    })
    $Control.add_MouseMove({
        param($sender, $e)
        if ($null -eq $script:dragOffset) { return }
        if ($script:widgetPinned) { $script:dragOffset = $null; return }
        if (($e.Button -band [System.Windows.Forms.MouseButtons]::Left) -eq 0) { return }
        $cursor = [System.Windows.Forms.Cursor]::Position
        $script:widgetForm.Location = New-Object System.Drawing.Point(($cursor.X - $script:dragOffset.X), ($cursor.Y - $script:dragOffset.Y))
    })
    $Control.add_MouseUp({ $script:dragOffset = $null })
}

function Initialize-TrayFoxBase {
    # Cache the brand fox (assets\tray-fox.png) as a 32x32 bitmap. An absent or
    # unreadable file is not an error: the tray falls back to the plain
    # drawn state glyph.
    $path = Join-Path (Get-Root) $script:TrayFoxRelativePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $src = [System.Drawing.Image]::FromFile($path)
        $bmp = New-Object System.Drawing.Bitmap 32, 32
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        try {
            $g.DrawImage($src, 1, 1, 30, 30)
        } finally {
            $g.Dispose()
            $src.Dispose()
        }
        $script:trayFoxBase = $bmp
    } catch {
        Write-Log 'Tray' 'FoxIconLoadFailed' "error=$($_.Exception.Message)"
        if ($null -ne $script:trayFoxBase) { $script:trayFoxBase.Dispose(); $script:trayFoxBase = $null }
    }
}

function Initialize-LogoFoxBase {
    # Header logo (design v2): the fox artwork from assets\logo-fox.png kept
    # at its native 48x48 so the header Paint can draw it sharp at 12x12.
    $path = Join-Path (Get-Root) $script:LogoFoxRelativePath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $bmp = New-Object System.Drawing.Bitmap($path)
        $script:logoFoxBase = $bmp
    } catch {
        Write-Log 'Tray' 'LogoFoxLoadFailed' "error=$($_.Exception.Message)"
        if ($null -ne $script:logoFoxBase) { $script:logoFoxBase.Dispose(); $script:logoFoxBase = $null }
    }
}

function New-TrayStateIcon {
    param(
        [Parameter(Mandatory = $true)][string]$Mode,
        [Parameter(Mandatory = $true)][System.Drawing.Color]$Color,
        [int]$SpinStep = 0
    )
    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $brush = New-Object System.Drawing.SolidBrush $Color
        $halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x55, $Color))
        try {
            if ($null -ne $script:trayFoxBase) {
                # Brand base: the fox owns the full 32px canvas and the state
                # glyph shrinks to a bottom-right badge so status stays
                # readable at the 16px tray size.
                $graphics.DrawImage($script:trayFoxBase, 0, 0, 32, 32)
                switch ($Mode) {
                    'error' {
                        $path = New-RoundedRectPath 11 11 3
                        $matrix = New-Object System.Drawing.Drawing2D.Matrix
                        $matrix.Translate(20, 20)
                        $path.Transform($matrix)
                        $graphics.FillPath($halo, $path)
                        $graphics.FillPath($brush, $path)
                        $path.Dispose()
                        $matrix.Dispose()
                    }
                    'spin' {
                        $angles = @(-90.0, 30.0, 150.0)
                        for ($i = 0; $i -lt 3; $i++) {
                            $penColor = $Color
                            $width = 1.5
                            if ($i -eq ($SpinStep % 3)) { $penColor = $script:ColorAccentHi; $width = 2.2 }
                            $pen = New-Object System.Drawing.Pen($penColor, $width)
                            $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                            $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                            $graphics.DrawArc($pen, 20, 20, 11, 11, $angles[$i], 70)
                            $pen.Dispose()
                        }
                    }
                    'paused' {
                        $graphics.FillRectangle($halo, 20, 20, 11, 11)
                        $graphics.FillRectangle($brush, 22, 22, 2, 7)
                        $graphics.FillRectangle($brush, 26, 22, 2, 7)
                    }
                    default {
                        $graphics.FillEllipse($halo, 20, 20, 11, 11)
                        $graphics.FillEllipse($brush, 21, 21, 9, 9)
                    }
                }
            } else {
            switch ($Mode) {
                'run' {
                    $graphics.FillEllipse($halo, 2, 2, 28, 28)
                    $graphics.FillEllipse($brush, 4, 4, 24, 24)
                }
                'error' {
                    $path = New-RoundedRectPath 26 26 5
                    $matrix = New-Object System.Drawing.Drawing2D.Matrix
                    $matrix.Translate(3, 3)
                    $path.Transform($matrix)
                    $graphics.FillPath($halo, $path)
                    $graphics.FillPath($brush, $path)
                    $path.Dispose()
                    $matrix.Dispose()
                }
                'spin' {
                    $angles = @(-90.0, 30.0, 150.0)
                    for ($i = 0; $i -lt 3; $i++) {
                        $penColor = $Color
                        $width = 3.0
                        if ($i -eq ($SpinStep % 3)) { $penColor = $script:ColorAccentHi; $width = 4.0 }
                        $pen = New-Object System.Drawing.Pen($penColor, $width)
                        $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
                        $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
                        $graphics.DrawArc($pen, 4, 4, 24, 24, $angles[$i], 70)
                        $pen.Dispose()
                    }
                }
                default {
                    $graphics.FillRectangle($halo, 7, 5, 7, 22)
                    $graphics.FillRectangle($halo, 18, 5, 7, 22)
                    $graphics.FillRectangle($brush, 9, 6, 4, 20)
                    $graphics.FillRectangle($brush, 19, 6, 4, 20)
                }
            }
            }
        } finally {
            $brush.Dispose()
            $halo.Dispose()
        }
        $handle = $bitmap.GetHicon()
        try {
            $handleIcon = [System.Drawing.Icon]::FromHandle($handle)
            $clonedIcon = [System.Drawing.Icon]$handleIcon.Clone()
            $handleIcon.Dispose()
            return $clonedIcon
        } finally {
            [void][ZapretLazy.Native.IconMethods]::DestroyIcon($handle)
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Update-TrayStateIcon {
    if ($null -eq $script:notifyIcon) { return }
    $color = $script:stateGlyphColor
    if ($null -eq $color) { $color = $script:ColorAccent }
    $icon = New-TrayStateIcon -Mode $script:stateGlyphMode -Color $color -SpinStep ([int]$script:spinStep)
    $old = $script:trayStateIcon
    $script:trayStateIcon = $icon
    $script:notifyIcon.Icon = $icon
    if ($null -ne $old) { $old.Dispose() }
}

function Set-ServiceDot {
    # State indicator per design/spec.md (glow approximated with a soft
    # translucent pass; SVG blur filters have no GDI+ equivalent).
    #   run     - soft green circle (working)
    #   paused  - orange pause bars (suspended)
    #   error   - red rounded square
    #   spin    - orange 3-segment wheel (check in progress)
    param([AllowNull()][string]$State, [AllowNull()][string]$Phase, [AllowNull()]$NetworkUp)
    $mode = 'paused'
    $color = $script:ColorAccent
    if ($Phase -eq 'error') { $mode = 'error'; $color = $script:ColorError }
    elseif ($Phase -eq 'paused') { $mode = 'paused'; $color = $script:ColorAccent }
    elseif ($Phase -eq 'boot' -or $Phase -eq 'update' -or $Phase -eq 'preflight' -or `
            $Phase -eq 'testing' -or $Phase -eq 'installing') { $mode = 'spin'; $color = $script:ColorAccent }
    elseif ($NetworkUp -eq $false) { $mode = 'error'; $color = $script:ColorError }
    elseif ($State -eq 'running') { $mode = 'run'; $color = $script:ColorOk }
    elseif ($State -eq 'error' -or $State -eq 'unknown') { $mode = 'error'; $color = $script:ColorError }
    if ($mode -ne $script:stateGlyphMode -or -not $color.Equals($script:stateGlyphColor)) {
        $script:stateGlyphMode = $mode
        $script:stateGlyphColor = $color
        if ($null -ne $script:brushStateGlyph) { $script:brushStateGlyph.Dispose() }
        if ($null -ne $script:penStateGlyph) { $script:penStateGlyph.Dispose() }
        $script:brushStateGlyph = New-Object System.Drawing.SolidBrush $color
        $script:penStateGlyph = New-Object System.Drawing.Pen($color, 1.6)
        $script:penStateGlyph.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $script:penStateGlyph.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        Sync-SpinTimer
        Update-TrayStateIcon
        if ($null -ne $script:pnlDot) { [void]$script:pnlDot.Invalidate() }
    }
}

function Sync-SpinTimer {
    if ($null -eq $script:spinTimer) { return }
    if ($script:stateGlyphMode -eq 'spin') {
        if (-not $script:spinTimer.Enabled) { [void]$script:spinTimer.Start() }
    } elseif ($script:spinTimer.Enabled) {
        $script:spinTimer.Stop()
    }
}

function Register-StateGlyphPaint {
    # 11x11 indicator in the status row. Geometry follows design/indicator-*.svg
    # scaled from the 13px viewBox by 11/13. Each shape is drawn twice: a
    # translucent halo pass, then the solid core.
    param([Parameter(Mandatory = $true)]$Panel)
    $Panel.add_Paint({
        param($sender, $e)
        if ($null -eq $script:brushStateGlyph) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $w = $sender.Width
        $h = $sender.Height
        $cx = $w / 2.0
        $cy = $h / 2.0
        $halo = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0x66, $script:stateGlyphColor))
        try {
            switch ($script:stateGlyphMode) {
                'spin' {
                    # Blink animation (design): three fixed 70-degree arcs; the
                    # leading arc is accent-light with a glow and hops to the
                    # next segment every SpinBlinkMs (120-degree steps).
                    $pad = 1.2
                    $aw = $w - 2 * $pad
                    $ah = $h - 2 * $pad
                    $segAngles = @(-90.0, 30.0, 150.0)
                    $lead = [int]$script:spinStep % 3
                    for ($si = 0; $si -lt 3; $si++) {
                        $isLead = ($si -eq $lead)
                        $penSeg = $script:penStateGlyph
                        if ($isLead) { $penSeg = $script:penStateHi }
                        if ($isLead) {
                            $penHaloB = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(0x55, $script:ColorAccentHi), 2.4)
                            $g.DrawArc($penHaloB, $pad, $pad, $aw, $ah, $segAngles[$si], 70)
                            $penHaloB.Dispose()
                        }
                        $g.DrawArc($penSeg, $pad, $pad, $aw, $ah, $segAngles[$si], 70)
                    }
                }
                'run' {
                    $g.FillEllipse($halo, 1, 1, ($w - 2), ($h - 2))
                    $g.FillEllipse($script:brushStateGlyph, 1.5, 1.5, ($w - 3), ($h - 3))
                }
                'error' {
                    $path = New-RoundedRectPath ([int]$w) ([int]$h) 2
                    $g.FillPath($halo, $path)
                    $path2 = New-RoundedRectPath ([int]$w) ([int]$h) 2
                    $g.FillPath($script:brushStateGlyph, $path2)
                    $path.Dispose()
                    $path2.Dispose()
                }
                default {
                    # paused: two vertical bars 3x9 (13px box) scaled to 11px.
                    $barW = 2.5
                    $barH = 7.6
                    $y = ($h - $barH) / 2.0
                    $g.FillRectangle($halo, 2.0, ($y - 0.8), ($barW + 1.6), ($barH + 1.6))
                    $g.FillRectangle($halo, 6.2, ($y - 0.8), ($barW + 1.6), ($barH + 1.6))
                    $g.FillRectangle($script:brushStateGlyph, 2.4, $y, $barW, $barH)
                    $g.FillRectangle($script:brushStateGlyph, 6.6, $y, $barW, $barH)
                }
            }
        } finally {
            $halo.Dispose()
        }
    })
}

function Sync-NetworkRows {
    # Two per-half centered readouts (design: halves (10,95)/(144,95), 124x14,
    # centered; address #9A9BA4, latency accent bold, timeout '-' dim).
    param($Network)
    $sampleList = New-Object System.Collections.Generic.List[object]
    $samples = Get-JsonProp $Network 'samples'
    if ($null -ne $samples) {
        foreach ($sample in $samples) { $sampleList.Add($sample) }
    }
    for ($half = 0; $half -lt 2; $half++) {
        $panel = $script:networkHalfPanels[$half]
        if ($null -eq $panel) { continue }
        if ($half -ge $sampleList.Count) {
            $panel.Tag.Text = ''
            [void]$panel.Invalidate()
            continue
        }
        $sample = $sampleList[$half]
        $target = [string](Get-JsonProp $sample 'target')
        $ms = Get-JsonProp $sample 'ms'
        if ([string]::IsNullOrWhiteSpace($target)) { $target = '?' }
        $panel.Tag.Target = $target
        if ($null -ne $ms) {
            $panel.Tag.Ms = ([string]$ms + ' ms')
            $panel.Tag.HasMs = $true
        } else {
            $panel.Tag.Ms = '-'
            $panel.Tag.HasMs = $false
        }
        [void]$panel.Invalidate()
    }
}

function Register-NetworkHalfPaint {
    param([Parameter(Mandatory = $true)]$Panel)
    $Panel.add_Paint({
        param($sender, $e)
        $tag = $sender.Tag
        if ($null -eq $tag -or [string]::IsNullOrEmpty($tag.Text) -and [string]::IsNullOrEmpty($tag.Target)) { return }
        if ([string]::IsNullOrEmpty($tag.Target)) { return }
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $flags = [System.Windows.Forms.TextFormatFlags]::SingleLine -bor `
                 [System.Windows.Forms.TextFormatFlags]::VerticalCenter
        $addrSize = [System.Windows.Forms.TextRenderer]::MeasureText($tag.Target, $script:fontNetwork, (New-Object System.Drawing.Size(0, 0)), $flags)
        $msSize = [System.Windows.Forms.TextRenderer]::MeasureText($tag.Ms, $script:fontNetworkSemi, (New-Object System.Drawing.Size(0, 0)), $flags)
        $gap = 6
        $blockW = $addrSize.Width + $gap + $msSize.Width
        $x = [int](($sender.Width - $blockW) / 2)
        if ($x -lt 0) { $x = 0 }
        $rect1 = New-Object System.Drawing.Rectangle($x, 0, $addrSize.Width, $sender.Height)
        [void][System.Windows.Forms.TextRenderer]::DrawText($g, $tag.Target, $script:fontNetwork, $rect1, $script:ColorButtonIdle, $flags)
        $msColor = $script:ColorMuted
        $msFont = $script:fontNetwork
        if ($tag.HasMs) { $msColor = $script:ColorAccent; $msFont = $script:fontNetworkSemi }
        $rect2 = New-Object System.Drawing.Rectangle(($x + $addrSize.Width + $gap), 0, $msSize.Width, $sender.Height)
        [void][System.Windows.Forms.TextRenderer]::DrawText($g, $tag.Ms, $msFont, $rect2, $msColor, $flags)
    })
}

function Get-ProgressLine {
    # Widget status core from status.progress: short English label per stage
    # ('Testing 5/21 - general (ALT3).bat' during testing); engines without a
    # progress object get the message line instead.
    param($Status)
    if ($null -eq $Status) { return '' }
    $message = [string](Get-JsonProp $Status 'message')
    $progress = Get-JsonProp $Status 'progress'
    if ($null -eq $progress) { return $message }
    $stage = [string](Get-JsonProp $progress 'stage')
    switch ($stage) {
        'boot'       { return 'booting...' }
        'preflight'  { return 'running preflight...' }
        'update'     { return 'checking for updates...' }
        'testing' {
            $line = 'testing'
            # Engine convention: index/total are 0 outside a real test run;
            # tolerate non-numeric values instead of throwing in the timer path.
            $totalNum = 0
            try { $totalNum = [int](Get-JsonProp $progress 'total') } catch { $totalNum = 0 }
            if ($totalNum -gt 0) {
                $indexNum = 0
                try { $indexNum = [int](Get-JsonProp $progress 'index') } catch { $indexNum = 0 }
                $line = ($line + ' ' + $indexNum + '/' + $totalNum)
            }
            $strategy = [string](Get-JsonProp $progress 'strategy')
            if (-not [string]::IsNullOrWhiteSpace($strategy)) {
                # Em dash separator (composed from codepoints: the source file
                # must stay ASCII so any ANSI codepage reads it correctly).
                $line = ($line + ' ' + [char]0x2014 + ' ' + $strategy)
            }
            return $line
        }
        'installing' {
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
            return 'applying strategy...'
        }
        # CONVENTIONS: stage 'done' = finished check (monitoring); the widget
        # keeps showing the final message until the per-boot auto-hide fires.
        'done' {
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
            return 'monitoring'
        }
        'monitoring' {
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
            return 'Monitoring'
        }
        'error' {
            if (-not [string]::IsNullOrWhiteSpace($message)) { return $message }
            return 'engine error'
        }
        default {
            # Unknown stage (newer engine): fall back to the message line.
            return $message
        }
    }
}

function Get-StatusMessageCore {
    # Progress line adapted to the combined status row: the strategy combo
    # already names the active strategy, so the core drops that duplication
    # ('Testing 3/10 - general.bat' -> 'Testing 3/10',
    #  'Active: general.bat - 42 checks OK' -> '42 checks OK').
    param($Status)
    $line = Get-ProgressLine $Status
    if ([string]::IsNullOrWhiteSpace($line)) { return '' }
    # Engine messages use the ASCII ' - ' separator; tray-composed Testing
    # lines use the em dash. Strip the strategy name after either.
    $sep = $line.IndexOf(' ' + [char]0x2014 + ' ')
    $sepLen = 3
    if ($sep -lt 0) { $sep = $line.IndexOf(' - '); $sepLen = 3 }
    if ($sep -lt 0) { return $line }
    $prefix = $line.Substring(0, $sep)
    if ($prefix -like 'Active: *') { return $line.Substring($sep + $sepLen) }
    if ($prefix -like 'Testing*') { return $prefix }
    return $line
}

function Update-StrategyStepper {
    # Rebuilds the strat stepper items from status.greenStrategies with events
    # suppressed: the engine-driven refresh must not echo a switch command.
    # No greens -> single disabled '(no green strategies)'; engine not up yet
    # -> single disabled 'Waiting for engine...'.
    param($Status)
    if ($script:pendingStrategy) {
        $activeNow = ''
        $phaseNow = ''
        if ($null -ne $Status) {
            $activeNow = [string](Get-JsonProp $Status 'activeStrategy')
            $phaseNow = [string](Get-JsonProp $Status 'phase')
        }
        $expired = ($null -ne $script:pendingDeadline -and (Get-Date) -ge $script:pendingDeadline)
        if ($activeNow -eq $script:pendingStrategy -or $phaseNow -eq 'error' -or $expired) {
            $script:pendingStrategy = ''
            $script:pendingDeadline = $null
        } else {
            return
        }
    }
    $script:comboSuppress = $true
    try {
        $st = $script:stepStrategy
        $greenList = New-Object System.Collections.Generic.List[object]
        if ($null -ne $Status) {
            $greens = Get-JsonProp $Status 'greenStrategies'
            if ($null -ne $greens) {
                foreach ($g in $greens) { $greenList.Add($g) }
            }
        }
        if ($null -eq $Status) {
            Set-ZlStepperEnabled $st $false
            Set-ZlStepperItems $st @('Waiting for engine...')
            Set-ZlStepperSelection $st 0
        } elseif ($greenList.Count -eq 0) {
            Set-ZlStepperEnabled $st $false
            Set-ZlStepperItems $st @('(no green strategies)')
            Set-ZlStepperSelection $st 0
        } else {
            $items = New-Object System.Collections.Generic.List[string]
            foreach ($g in $greenList) { $items.Add([string]$g) }
            Set-ZlStepperItems $st $items.ToArray()
            Set-ZlStepperEnabled $st $true
            $active = [string](Get-JsonProp $Status 'activeStrategy')
            $idx = $st.Items.IndexOf($active)
            if ($idx -lt 0) { $idx = 0 }
            Set-ZlStepperSelection $st $idx
        }
    } finally {
        $script:comboSuppress = $false
    }
}

function Sync-OptionSteppers {
    # Keep optimistic values until the engine acknowledges the applied state.
    param($Status)
    if ($null -eq $Status) { return }
    $game = [string](Get-JsonProp $Status 'gameFilterMode')
    $ipset = [string](Get-JsonProp $Status 'ipsetMode')
    $phase = [string](Get-JsonProp $Status 'phase')
    $expired = ($null -ne $script:pendingDeadline -and (Get-Date) -ge $script:pendingDeadline)
    if ($script:pendingGame) {
        if (($game -eq $script:pendingGame -and $phase -eq 'monitoring') -or $phase -eq 'error' -or $expired) {
            $script:pendingGame = ''
            $script:pendingDeadline = $null
            Set-ZlStepperEnabled $script:stepGame $true
        }
    }
    if ($script:pendingIpset) {
        if (($ipset -eq $script:pendingIpset -and $phase -eq 'monitoring') -or $phase -eq 'error' -or $expired) {
            $script:pendingIpset = ''
            $script:pendingDeadline = $null
            Set-ZlStepperEnabled $script:stepIpset $true
        }
    }
    if (-not $script:pendingGame -and -not [string]::IsNullOrWhiteSpace($game)) {
        $idx = $script:stepGame.Items.IndexOf($game)
        if ($idx -ge 0 -and $idx -ne $script:stepGame.SelectedIndex) { Set-ZlStepperSelection $script:stepGame $idx }
    }
    if (-not $script:pendingIpset -and -not [string]::IsNullOrWhiteSpace($ipset)) {
        $idx = $script:stepIpset.Items.IndexOf($ipset)
        if ($idx -ge 0 -and $idx -ne $script:stepIpset.SelectedIndex) { Set-ZlStepperSelection $script:stepIpset $idx }
    }
}

function Sync-ScheduleCombo {
    # Selects the persisted test-schedule label (events suppressed: the
    # programmatic selection is not a user change and must not re-save).
    $script:scheduleSuppress = $true
    try {
        $current = Get-TestScheduleValue
        $label = [string]$script:TestScheduleLabels[$current]
        $dd = $script:ddSchedule
        for ($i = 0; $i -lt $dd.Items.Count; $i++) {
            if ($dd.Items[$i] -eq $label) { Set-ZlDropdownSelection $dd $i; break }
        }
    } finally {
        $script:scheduleSuppress = $false
    }
}

function Format-StatusUpdateStamp {
    param($Status)
    $iso = [string](Get-JsonProp $Status 'lastTestAt')
    if ([string]::IsNullOrWhiteSpace($iso)) { $iso = [string](Get-JsonProp $Status 'updatedAt') }
    if ([string]::IsNullOrWhiteSpace($iso)) { return '' }
    try {
        $dt = [datetime]::Parse($iso, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal)
        return ('upd ' + $dt.ToLocalTime().ToString('dd.MM HH:mm'))
    } catch { return '' }
}

function Format-FooterVersionText {
    param([AllowNull()][string]$PayloadVersion)
    if ([string]::IsNullOrWhiteSpace($PayloadVersion)) { $PayloadVersion = [string][char]0x2014 }
    if ([string]::IsNullOrWhiteSpace($script:appVersion)) {
        try {
            $exe = [Environment]::GetCommandLineArgs()[0]
            $script:appVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).FileVersion
            if ($script:appVersion -match '^(?<short>\d+\.\d+\.\d+)\.0$') {
                $script:appVersion = $Matches.short
            }
        } catch {
            $script:appVersion = [string][char]0x2014
        }
    }
    return ('zapret v' + $PayloadVersion + "`n" + 'zlazy v' + $script:appVersion)
}

function Sync-StatusLayout {
    # Fixed status row for every state (run / paused / error / checking):
    # dot (10,121) 11x11, text box (24,120) 244x14 left-aligned + ellipsis.
    # Re-applied on every refresh so nothing can leave it displaced.
    param([Parameter(Mandatory = $true)][bool]$Checking)
    try {
        $script:pnlDot.SetBounds($script:StatusDotX, $script:StatusDotTop, $script:StatusDotSize, $script:StatusDotSize)
        $script:lblStatus.SetBounds($script:StatusBox[0], $script:StatusBox[1], $script:StatusBox[2], $script:StatusBox[3])
    } catch { }
}

function Update-TrayUi {
    # Refreshes widget controls from a status object; $null = engine not ready yet.
    param($Status)
    $script:lastStatus = $Status
    if ($null -eq $Status) {
        Update-StrategyStepper $null
        Set-ZlText $script:lblStatus 'engine not ready'
        Sync-StatusLayout $false
        Set-ServiceDot 'none' ''
        Sync-NetworkRows $null
        Set-ZlText $script:lblVersion (Format-FooterVersionText $null)
        return
    }
    Update-StrategyStepper $Status
    Sync-OptionSteppers $Status
    $stateText = [string](Get-JsonProp $Status 'serviceState')
    if ([string]::IsNullOrWhiteSpace($stateText)) { $stateText = 'unknown' }
    $progressStage = ''
    try { $progressStage = [string](Get-JsonProp (Get-JsonProp $Status 'progress') 'stage') } catch { }
    $phaseText = [string](Get-JsonProp $Status 'phase')
    $isChecking = ($progressStage -eq 'boot' -or $progressStage -eq 'update' -or $progressStage -eq 'preflight' -or `
        $progressStage -eq 'testing' -or $progressStage -eq 'installing')
    if ($script:pendingStrategy -and $phaseText -ne 'error') {
        $isChecking = $true
        $phaseText = 'installing'
    }
    if ($isChecking) {
        # transitional phases: the FULL progress line incl. strategy name,
        # ellipsized by the label (design artboard-checking)
        if ($script:pendingStrategy) {
            $statusText = 'Switching strategy - ' + (Get-StepperDisplayValue 'strat' $script:pendingStrategy)
        } else {
            $statusText = Get-ProgressLine $Status
        }
    } elseif ($phaseText -eq 'paused') {
        # VPN pause (engine stopped winws): compact line next to the pause bars.
        $statusText = 'vpn: on ' + [char]0x00B7 + ' lazy paused'
    } else {
        $displayState = $stateText
        if ($stateText -eq 'running') { $displayState = 'run' }
        $statusText = 'service: ' + $displayState
        $stamp = Format-StatusUpdateStamp $Status
        if ($stamp) { $statusText = ($statusText + ' ' + [char]0x00B7 + ' ' + $stamp) }
    }
    Set-ZlText $script:lblStatus $statusText
    Sync-StatusLayout $isChecking
    $network = Get-JsonProp $Status 'network'
    Set-ServiceDot $stateText $phaseText (Get-JsonProp $network 'up')
    Sync-NetworkRows $network
    $version = [string](Get-JsonProp $Status 'payloadVersion')
    Set-ZlText $script:lblVersion (Format-FooterVersionText $version)
}

function Update-AutoHide {
    # Per-boot auto-hide: once the engine reaches a finished phase ('monitoring'
    # or 'error') the widget keeps showing the final message for
    # autoHideDelaySec, then hides WITHOUT persisting widget.visible - the next
    # boot shows the widget again. Any manual toggle cancels it for this session.
    param($Status)
    if ($script:widgetPinned) { return }
    if ($script:autoHideState -eq 'done') { return }
    if ($script:autoHideCancelled -or -not $script:autoHideEnabled) {
        $script:autoHideState = 'done'
        return
    }
    $phase = ''
    if ($null -ne $Status) { $phase = [string](Get-JsonProp $Status 'phase') }
    if ($phase -ne 'monitoring' -and $phase -ne 'error' -and $phase -ne 'paused') {
        # Check still running or engine not ready: (re)arm the countdown.
        $script:autoHideState = 'armed'
        return
    }
    if ($script:autoHideState -eq 'armed') {
        $script:autoHideState = 'countdown'
        $script:autoHideDeadline = (Get-Date).AddSeconds($script:autoHideDelaySec)
        return
    }
    if ((Get-Date) -ge $script:autoHideDeadline) {
        $script:autoHideState = 'done'
        $script:widgetForm.Visible = $false
        $script:geometryDirty = $false
        Write-Log 'Tray' 'WidgetAutoHidden' "delaySec=$script:autoHideDelaySec"
    }
}

function Show-TrayBalloon {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Text,
        [System.Windows.Forms.ToolTipIcon]$Icon = [System.Windows.Forms.ToolTipIcon]::Info
    )
    try {
        [void]$script:notifyIcon.ShowBalloonTip($script:BalloonTimeoutMs, $Title, $Text, $Icon)
    } catch {
        Write-Log 'Tray' 'BalloonFailed' "error=$($_.Exception.Message)"
    }
}

function Update-BalloonState {
    # Balloon only on activeStrategy change or phase transitioning to error.
    # First successful read primes the baseline silently.
    param($Status)
    if ($null -eq $Status) { return }
    $active = [string](Get-JsonProp $Status 'activeStrategy')
    $phase = [string](Get-JsonProp $Status 'phase')
    if (-not $script:balloonPrimed) {
        $script:balloonPrimed = $true
        $script:lastActiveStrategy = $active
        $script:lastPhase = $phase
        return
    }
    if ($phase -eq 'paused') {
        # VPN pause: activeStrategy may be the remembered one shown for display
        # only; no balloon, and the baseline is kept for the resume.
        $script:lastPhase = $phase
        return
    }
    if (-not [string]::IsNullOrWhiteSpace($active) -and $active -ne $script:lastActiveStrategy) {
        Show-TrayBalloon 'Strategy switched' ('Active: ' + $active) Info
    }
    if ($phase -eq 'error' -and $script:lastPhase -ne 'error') {
        $message = [string](Get-JsonProp $Status 'message')
        if ([string]::IsNullOrWhiteSpace($message)) { $message = 'Engine entered error phase' }
        Show-TrayBalloon 'zapret lazy error' $message Error
    }
    $script:lastActiveStrategy = $active
    $script:lastPhase = $phase
}

function Set-WidgetPinned {
    param([Parameter(Mandatory = $true)][bool]$Pinned)
    $script:widgetPinned = $Pinned
    $script:dragOffset = $null
    $script:autoHideCancelled = $false
    $script:autoHideState = 'armed'
    $script:autoHideDeadline = $null
    if ($null -ne $script:pnlPin) { [void]$script:pnlPin.Invalidate() }
    Save-WidgetPrefs $script:widgetForm.Visible
    Write-Log 'Tray' 'WidgetPinnedChanged' "pinned=$Pinned"
}

function Hide-Widget {
    $script:autoHideCancelled = $true  # manual hide cancels the per-boot auto-hide
    $script:widgetForm.Visible = $false
    $script:geometryDirty = $false
    Save-WidgetPrefs $false
}

function Show-Widget {
    $script:autoHideCancelled = $true  # manual show cancels the per-boot auto-hide
    $script:widgetForm.Visible = $true
    Save-WidgetPrefs $true
}

function Toggle-Widget {
    try {
        if ($script:widgetForm.Visible) { Hide-Widget } else { Show-Widget }
    } catch {
        Write-Log 'Tray' 'WidgetToggleFailed' "error=$($_.Exception.Message)"
    }
}

function Sync-MenuToggleText {
    # kept for compatibility: no-op with the custom menu (toggle text is set
    # when the item list is built).
    param($Item)
}

function New-ExitHandler {
    # Exit stops the whole application; closing/hiding the widget does not.
    return {
        Send-ShutdownCommand
        try {
            Save-WidgetPrefs $script:widgetForm.Visible
        } catch {
            Write-Log 'Tray' 'WidgetPrefsSaveFailed' "error=$($_.Exception.Message)"
        }
        Write-Log 'Tray' 'Exit' 'shutdown requested'
        $script:notifyIcon.Visible = $false
        if ($null -ne $script:appContext) { $script:appContext.ExitThread() }
    }
}

function New-OpenFolderAction {
    param([Parameter(Mandatory = $true)][string]$FolderName)
    return {
        try {
            Start-Process 'explorer.exe' (Join-Path (Get-Root) $FolderName)
        } catch {
            Write-Log 'Tray' 'OpenFolderFailed' "folder=$FolderName error=$($_.Exception.Message)"
        }
    }.GetNewClosure()
}

function Get-TrayMenuItems {
    return @(Get-WidgetMenuItems)
}

function Get-WidgetMenuItems {
    # Header '(three-dot)' menu: the same actions the pre-redesign tray menu performed.
    $toggleText = 'Hide widget'
    $pinText = 'Pin widget'
    if ($script:widgetPinned) { $pinText = 'Unpin widget' }
    try { if (-not $script:widgetForm.Visible) { $toggleText = 'Show widget' } } catch { }
    return @(
        @{ Text = $toggleText; Action = { Toggle-Widget } },
        @{ Text = $pinText; Action = { Set-WidgetPinned (-not $script:widgetPinned) } },
        @{ Text = 'Retest now'; Action = { Send-RetestCommand } },
        @{ Text = 'Open logs'; Action = (New-OpenFolderAction 'logs') },
        @{ Text = 'Open reports'; Action = (New-OpenFolderAction 'reports') },
        @{ Text = 'GitHub'; Action = { Start-Process 'https://github.com/snovosk/zapret-lazy' } },
        @{ Separator = $true },
        @{ Text = 'Exit'; Action = (New-ExitHandler) }
    )
}

function Set-WidgetToolWindow {
    param([Parameter(Mandatory = $true)]$Form)
    $style = [ZapretLazy.Native.WindowMethods]::GetWindowLongPtr($Form.Handle, -20).ToInt64()
    $updated = ($style -bor [long]0x80) -band (-bnot [long]0x40000)
    [void][ZapretLazy.Native.WindowMethods]::SetWindowLongPtr($Form.Handle, -20, [IntPtr]::new($updated))
}

function New-WidgetForm {
    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'zapret lazy'
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ClientSize = New-Object System.Drawing.Size($script:WidgetWidth, $script:WidgetHeight)
    $form.BackColor = $script:ColorCardBg
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.Location = New-Object System.Drawing.Point(60, 60)
    $form.ShowInTaskbar = $false
    $form.TopMost = $false
    $form.ShowIcon = $false
    $form.add_HandleCreated({ Set-WidgetToolWindow $this })
    $form.add_Shown({ Set-WidgetToolWindow $this })
    # Scale the absolute layout on high-DPI displays so rows never overlap.
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi

    # Consolas 9 for controls; the two-line version footer uses a compact 7 pt.
    $script:fontTitle       = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
    $script:fontCaption     = New-Object System.Drawing.Font('Consolas', 9)
    $script:fontCombo       = New-Object System.Drawing.Font('Consolas', 9)
    $script:fontStatus      = $script:fontCombo
    $script:fontNetwork     = $script:fontCombo
    $script:fontNetworkSemi = New-Object System.Drawing.Font('Consolas', 9, [System.Drawing.FontStyle]::Bold)
    $script:fontFooter      = New-Object System.Drawing.Font('Consolas', 7)
    $script:fontMenuButton  = $script:fontCombo
    $script:fontCloseButton = $script:fontCombo
    $script:brushAccent     = New-Object System.Drawing.SolidBrush $script:ColorAccent
    $script:brushComboRow   = New-Object System.Drawing.SolidBrush $script:ColorComboBg
    $script:penBorder       = New-Object System.Drawing.Pen $script:ColorBorder
    $script:penAccent       = New-Object System.Drawing.Pen $script:ColorAccent
    $script:stateGlyphColor = $script:ColorAccent
    $script:brushStateGlyph = New-Object System.Drawing.SolidBrush $script:ColorAccent
    $script:penStateGlyph   = New-Object System.Drawing.Pen($script:ColorAccent, 1.6)
    $script:penStateGlyph.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:penStateGlyph.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:penStateHi      = New-Object System.Drawing.Pen($script:ColorAccentHi, 1.6)
    $script:penStateHi.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:penStateHi.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

    # Spinner animation for the 'check in progress' wheel.
    $spin = New-Object System.Windows.Forms.Timer
    $spin.Interval = 500
    $script:spinTimer = $spin
    $spin.add_Tick({
        $script:spinStep = ([int]$script:spinStep + 1) % 3
        Update-TrayStateIcon
        if ($null -ne $script:pnlDot) { [void]$script:pnlDot.Invalidate() }
    })

    # Rounded window region: no native title bar, transparent corners.
    $regionPath = New-RoundedRectPath $script:WidgetWidth $script:WidgetHeight
    $form.Region = New-Object System.Drawing.Region $regionPath
    $regionPath.Dispose()

    # 1px card border (the docked header panel repaints the covered top part).
    $form.add_Paint({
        param($sender, $e)
        $path = New-RoundedRectPath $sender.ClientSize.Width $sender.ClientSize.Height
        $e.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $e.Graphics.DrawPath($script:penBorder, $path)
        $path.Dispose()
    })

    # --- Header (design v2: fox logo (10,7) 12px, title (27,6), icon buttons) -
    $script:pnlHeader = New-Object System.Windows.Forms.Panel
    $script:pnlHeader.BackColor = $script:ColorHeaderBg
    $script:pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
    $script:pnlHeader.Height = $script:HeaderHeight
    [void]$form.Controls.Add($script:pnlHeader)
    $script:pnlHeader.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $d = $script:WidgetCornerRadius * 2
        $g.DrawLine($script:penBorder, $script:WidgetCornerRadius, 0, ($sender.Width - $script:WidgetCornerRadius), 0)
        $g.DrawArc($script:penBorder, 0, 0, $d, $d, 180, 90)
        $g.DrawArc($script:penBorder, ($sender.Width - $d - 1), 0, $d, $d, 270, 90)
        $g.DrawLine($script:penBorder, 0, $script:WidgetCornerRadius, 0, $sender.Height)
        $g.DrawLine($script:penBorder, ($sender.Width - 1), $script:WidgetCornerRadius, ($sender.Width - 1), $sender.Height)
        if ($null -ne $script:logoFoxBase) {
            # Brand fox as the header logo (design v2: 12x12 at (10,7),
            # assets\logo-fox.png with transparent background).
            $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.DrawImage($script:logoFoxBase, $script:HeaderLogoLeft, $script:HeaderLogoTop, $script:HeaderLogoSize, $script:HeaderLogoSize)
        } else {
            $g.FillEllipse($script:brushAccent, $script:HeaderLogoLeft, $script:HeaderLogoTop, $script:HeaderLogoSize, $script:HeaderLogoSize)
        }
    })

    $script:lblTitle = New-ValueLabel -Parent $script:pnlHeader -Left $script:HeaderTitleLeft -Top 6 -Width 180 -Height 14 -Color $script:ColorText -Back $script:ColorHeaderBg
    $script:lblTitle.Font = $script:fontTitle
    Set-ZlText $script:lblTitle 'zapret lazy'

    $script:pnlPin = New-Object System.Windows.Forms.Panel
    $script:pnlPin.SetBounds(214, 7, 12, 12)
    $script:pnlPin.BackColor = $script:ColorHeaderBg
    $script:pnlPin.Tag = @{ Hover = $false }
    $script:pnlPin.Cursor = [System.Windows.Forms.Cursors]::Hand
    $script:pnlPin.Visible = $true
    $script:pnlPin.add_Paint({
        param($sender, $e)
        $g = $e.Graphics
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $color = $script:ColorButtonIdle
        if ($script:widgetPinned -or $sender.Tag.Hover) { $color = $script:ColorAccent }
        $brush = New-Object System.Drawing.SolidBrush $color
        # design/icon-pin.svg: exact 12x12 path, shared vertical center with ⋮/✕.
        $path = New-Object System.Drawing.Drawing2D.GraphicsPath
        $path.AddBezier(2.6, 1.5, 2.6, 1.0667, 2.8667, 0.8, 3.3, 0.8)
        $path.AddLine(3.3, 0.8, 8.7, 0.8)
        $path.AddBezier(8.7, 0.8, 9.1333, 0.8, 9.4, 1.0667, 9.4, 1.5)
        $path.AddBezier(9.4, 1.5, 9.4, 1.9333, 9.1333, 2.3, 8.7, 2.3)
        $path.AddLine(8.7, 2.3, 7.1, 2.3)
        $path.AddLine(7.1, 2.3, 7.1, 4.6)
        $path.AddBezier(7.1, 4.6, 8.3, 5.2, 9.4, 6.3, 9.4, 7.6)
        $path.AddLine(9.4, 7.6, 9.4, 8.3)
        $path.AddLine(9.4, 8.3, 2.6, 8.3)
        $path.AddLine(2.6, 8.3, 2.6, 7.6)
        $path.AddBezier(2.6, 7.6, 2.6, 6.3, 3.7, 5.2, 4.9, 4.6)
        $path.AddLine(4.9, 4.6, 4.9, 2.3)
        $path.AddLine(4.9, 2.3, 3.3, 2.3)
        $path.AddBezier(3.3, 2.3, 2.8667, 2.3, 2.6, 1.9333, 2.6, 1.5)
        $path.CloseFigure()
        $g.FillPath($brush, $path)
        $g.FillRectangle($brush, 5.5, 8.3, 1.0, 3.3)
        $path.Dispose()
        $brush.Dispose()
    })
    $script:pnlPin.add_MouseEnter({ $this.Tag.Hover = $true; [void]$this.Invalidate() })
    $script:pnlPin.add_MouseLeave({ $this.Tag.Hover = $false; [void]$this.Invalidate() })
    $script:pnlPin.add_Click({ Set-WidgetPinned (-not $script:widgetPinned) })
    [void]$script:pnlHeader.Controls.Add($script:pnlPin)

    $script:btnMenu = New-IconButton -Parent $script:pnlHeader -Bounds $script:MenuButtonBounds -Kind 'dots'
    $script:btnMenu.add_Click({
        try {
            Show-ZlMenu $script:btnMenu (Get-WidgetMenuItems)
        } catch {
            Write-Log 'Tray' 'MenuShowFailed' "error=$($_.Exception.Message)"
        }
    })

    $script:btnClose = New-IconButton -Parent $script:pnlHeader -Bounds $script:CloseButtonBounds -Kind 'close'
    $script:btnClose.add_Click({ Hide-Widget })

    Register-DragMove $script:pnlHeader
    Register-DragMove $script:lblTitle

    # --- Setting fields (design v2: steppers '<' '>' at (10,37)/(10,65)/(10,93))
    $fieldW = $script:WidgetWidth - (2 * $script:Margin)
    $script:stepStrategy = New-ZlStepper $form $script:Margin $script:RowStrategyTop $fieldW $script:FieldHeight 'strat'
    $script:stepStrategy.OnStep = {
        param($selected)
        if ($script:comboSuppress -or $script:pendingStrategy) { return }
        $active = ''
        if ($null -ne $script:lastStatus) { $active = [string](Get-JsonProp $script:lastStatus 'activeStrategy') }
        if ([string]$selected -eq $active) { return }
        if ([string]::IsNullOrWhiteSpace([string]$selected) -or $selected -like '(*') { return }
        $script:pendingStrategy = [string]$selected
        $script:pendingDeadline = (Get-Date).AddSeconds($script:PendingSelectionTimeoutSec)
        Set-ZlStepperEnabled $script:stepStrategy $false
        Set-ZlText $script:lblStatus ('Switching strategy - ' + (Get-StepperDisplayValue 'strat' ([string]$selected)))
        Sync-StatusLayout $true
        Set-ServiceDot 'running' 'installing' $null
        Send-SwitchCommand ([string]$selected)
    }
    $script:stepGame = New-ZlStepper $form $script:Margin $script:RowGameFilterTop $fieldW $script:FieldHeight 'game filter'
    Set-ZlStepperItems $script:stepGame @('disabled', 'all', 'tcp', 'udp')
    $script:stepGame.OnStep = {
        param($selected)
        if ($script:comboSuppress -or $script:pendingGame) { return }
        $script:pendingGame = [string]$selected
        $script:pendingDeadline = (Get-Date).AddSeconds($script:PendingSelectionTimeoutSec)
        Set-ZlStepperEnabled $script:stepGame $false
        Send-OptionCommand 'gameFilterMode' ([string]$selected)
    }
    $script:stepIpset = New-ZlStepper $form $script:Margin $script:RowIpsetTop $fieldW $script:FieldHeight 'ipset list'
    Set-ZlStepperItems $script:stepIpset @('none', 'loaded', 'any')
    $script:stepIpset.OnStep = {
        param($selected)
        if ($script:comboSuppress -or $script:pendingIpset) { return }
        $script:pendingIpset = [string]$selected
        $script:pendingDeadline = (Get-Date).AddSeconds($script:PendingSelectionTimeoutSec)
        Set-ZlStepperEnabled $script:stepIpset $false
        Send-OptionCommand 'ipsetMode' ([string]$selected)
    }

    # --- Status row: fixed dot, left-aligned text right after it -------------
    $script:pnlDot = New-Object System.Windows.Forms.Panel
    $script:pnlDot.SetBounds($script:StatusDotX, $script:StatusDotTop, $script:StatusDotSize, $script:StatusDotSize)
    $script:pnlDot.BackColor = $script:ColorCardBg
    Register-StateGlyphPaint $script:pnlDot
    [void]$form.Controls.Add($script:pnlDot)

    $script:lblStatus = New-ValueLabel -Parent $form `
        -Left $script:StatusBox[0] -Top $script:StatusBox[1] `
        -Width $script:StatusBox[2] -Height $script:StatusBox[3] `
        -Color $script:ColorComboText
    $script:lblStatus.AutoEllipsis = $true
    $script:lblStatus.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    Set-ZlText $script:lblStatus 'engine not ready'

    # Mouse wheel over a stepper field steps it (panels cannot take focus, so
    # the wheel is routed at form level from the cursor position).
    $form.add_MouseWheel({
        param($sender, $e)
        try {
            $pt = $sender.PointToClient([System.Windows.Forms.Cursor]::Position)
            $dir = -1
            if ($e.Delta -lt 0) { $dir = 1 }
            foreach ($st in @($script:stepStrategy, $script:stepGame, $script:stepIpset)) {
                if ($null -eq $st) { continue }
                if ($st.Panel.Bounds.Contains($pt)) { Step-ZlStepper $st $dir; break }
            }
        } catch { }
    })

    # --- Network halves (design: centered readouts per half) -----------------
    $halfDefs = @(
        @(($script:NetworkHalf1Left), $script:RowNetworkTop, $script:NetworkHalfWidth),
        @(($script:NetworkHalf2Left), $script:RowNetworkTop, $script:NetworkHalfWidth)
    )
    for ($hi = 0; $hi -lt 2; $hi++) {
        $np = New-Object System.Windows.Forms.Panel
        $np.SetBounds($halfDefs[$hi][0], $halfDefs[$hi][1], $halfDefs[$hi][2], $script:RowNetworkHeight)
        $np.BackColor = $script:ColorCardBg
        $np.Tag = @{ Text = ''; Target = ''; Ms = ''; HasMs = $false }
        Register-NetworkHalfPaint $np
        [void]$form.Controls.Add($np)
        $script:networkHalfPanels[$hi] = $np
    }

    # --- Footer (design v2: schedule dropdown (10,158); 'zapret v…' right 268)
    $script:ddSchedule = New-ZlDropdown $form $script:Margin $script:RowFooterTop `
        $script:ComboScheduleWidth $script:ComboScheduleHeight
    foreach ($value in $script:TestScheduleValues) {
        [void]$script:ddSchedule.Items.Add([string]$script:TestScheduleLabels[$value])
    }
    $script:ddSchedule.OnSelect = {
        param($selected)
        if ($script:scheduleSuppress) { return }
        foreach ($key in $script:TestScheduleLabels.Keys) {
            if ($script:TestScheduleLabels[$key] -eq [string]$selected) {
                Set-TestScheduleValue $key
                return
            }
        }
    }

    $script:lblVersion = New-ValueLabel -Parent $form `
        -Left $script:VersionLeft -Top $script:VersionTop `
        -Width ($script:VersionRightEdge - $script:VersionLeft) -Height $script:VersionRowHeight -Color $script:ColorMuted
    $script:lblVersion.Font = $script:fontFooter
    $script:lblVersion.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
    Set-ZlText $script:lblVersion (Format-FooterVersionText $null)

    # Close button hides the widget (tray 'Show widget' brings it back).
    $form.add_FormClosing({
        param($sender, $e)
        try {
            $e.Cancel = $true
            Hide-Widget
        } catch {
            Write-Log 'Tray' 'WidgetCloseFailed' "error=$($_.Exception.Message)"
        }
    })

    # Dragging marks geometry dirty; the 2 s timer persists once the position
    # is stable (avoids a Save-Config per mouse-move event).
    $form.add_Move({
        try {
            if (-not $script:geometryApplied) { return }
            if (-not $this.Visible) { return }
            $script:pendingPoint = $this.Location
            $script:geometryDirty = $true
            $script:geometryQuiet = 0
        } catch {
            Write-Log 'Tray' 'WidgetMoveFailed' "error=$($_.Exception.Message)"
        }
    })

    return $form
}

function Initialize-TrayIcon {
    $script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
    Initialize-TrayFoxBase
    Update-TrayStateIcon
    $script:notifyIcon.Text = 'zapret lazy'
    $script:notifyIcon.Visible = $true
    $script:notifyIcon.add_DoubleClick({ Toggle-Widget })
    $script:notifyIcon.add_MouseUp({
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
            try { Show-ZlMenu $null (Get-TrayMenuItems) } catch {
                Write-Log 'Tray' 'MenuShowFailed' "error=$($_.Exception.Message)"
            }
        }
    })
}

function Initialize-Timer {
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = $script:TimerIntervalMs
    $script:uiTimer = $timer # keep a root reference; a local-only Timer can be GC'd
    $timer.add_Tick({
        try {
            $status = Read-Status
            Update-TrayUi $status
            Update-BalloonState $status
            Update-AutoHide $status
            if ($script:geometryDirty) {
                $script:geometryQuiet++
                $loc = $script:widgetForm.Location
                if ($null -ne $script:pendingPoint -and
                    $loc.X -eq $script:pendingPoint.X -and $loc.Y -eq $script:pendingPoint.Y -and
                    $script:geometryQuiet -ge $script:GeometryQuietTicks) {
                    $script:geometryDirty = $false
                    Save-WidgetPrefs $script:widgetForm.Visible
                } else {
                    $script:pendingPoint = $loc
                    $script:geometryQuiet = 0
                }
            }
        } catch {
            # Timer path must never take the tray app down.
            Write-Log 'Tray' 'StatusReadFailed' "error=$($_.Exception.Message)"
        }
    })
    [void]$timer.Start()
}

function Initialize-SingleInstance {
    $script:singleMutex = New-Object System.Threading.Mutex($false, $script:SingleInstanceMutex)
    $acquired = $false
    try {
        $acquired = $script:singleMutex.WaitOne(0)
    } catch {
        $acquired = $true
    }
    if (-not $acquired) {
        Write-Log 'Tray' 'AlreadyRunning' 'another tray instance holds the mutex'
        exit 0
    }
    $script:trayLockPath = Join-Path (Get-TrayStateDir) 'tray.lock'
    try {
        [string]$PID | Set-Content -Path $script:trayLockPath -Encoding ASCII
    } catch {
        Write-Log 'Tray' 'LockWriteFailed' "path=$script:trayLockPath error=$($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
function Invoke-ZlazyTray {
Initialize-SingleInstance

try {
    Initialize-LogoFoxBase
    $script:widgetForm = New-WidgetForm
    Sync-ScheduleCombo

    # Apply persisted geometry once. The widget itself is ALWAYS shown at
    # startup so the user can watch the boot check progress; widget.visible
    # only holds the post-boot manual state (auto-hide never rewrites it).
    $cfg = Get-Config
    Ensure-WidgetSection $cfg
    $wx = $cfg.widget.x
    $wy = $cfg.widget.y
    if ($null -ne $wx -and $null -ne $wy) {
        $script:widgetForm.Location = New-Object System.Drawing.Point([int]$wx, [int]$wy)
    }
    $script:autoHideEnabled = ($cfg.widget.autoHideAfterBoot -eq $true)
    $script:autoHideDelaySec = [int]$cfg.widget.autoHideDelaySec
    $script:widgetPinned = ($cfg.widget.pinned -eq $true)
    [void]$script:pnlPin.Invalidate()
    $script:widgetForm.Visible = $true
    $script:geometryApplied = $true

    Initialize-TrayIcon
    Initialize-Timer

    # Initial paint from the current snapshot; balloon baseline primed silently.
    $initialStatus = Read-Status
    Update-TrayUi $initialStatus
    if ($null -ne $initialStatus) {
        $script:balloonPrimed = $true
        $script:lastActiveStrategy = [string](Get-JsonProp $initialStatus 'activeStrategy')
        $script:lastPhase = [string](Get-JsonProp $initialStatus 'phase')
    }

    $script:appContext = New-Object System.Windows.Forms.ApplicationContext
    [void][System.Windows.Forms.Application]::Run($script:appContext)
} finally {
    try { if ($null -ne $script:notifyIcon) { $script:notifyIcon.Visible = $false } } catch {}
    try { if ($null -ne $script:trayStateIcon) { $script:trayStateIcon.Dispose() } } catch {}
    try { if ($null -ne $script:singleMutex) { $script:singleMutex.ReleaseMutex() } } catch {}
    try { if ($null -ne $script:trayLockPath -and (Test-Path $script:trayLockPath)) { Remove-Item -Force $script:trayLockPath } } catch {}
}
}

Invoke-ZlazyTray
