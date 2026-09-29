<#
.SYNOPSIS
    WinSweep tray icon. It runs the automatic cleanups.

.DESCRIPTION
    While this icon is next to the clock, WinSweep is active: at the day and time set in the
    settings window, the icon starts a cleanup (the "WinSweep\Cleanup" scheduled task, which
    runs WinSweep.ps1 with admin rights). If the PC was off or the icon was closed at that
    time, the cleanup runs a few minutes after the icon starts again.

    Close the icon (right-click > Close WinSweep) and nothing runs in the background until
    WinSweep is opened again from the Start menu. The icon starts at every sign-in.

    Click the icon to open the settings window. Hover over it to see the next cleanup.
    It runs as the signed-in user, without admin rights, and never deletes anything itself.

.PARAMETER Open
    Also open the settings window (used by the Start menu shortcut). If the icon is already
    running, only the window opens.

.PARAMETER ExportIcon
    Write the WinSweep icon (.ico) to this path and exit. The installer uses it for the
    Start menu shortcut and the settings window.
#>
param([switch]$Open, [string]$ExportIcon)

Add-Type -AssemblyName System.Drawing

# ----------------------------- Icon ------------------------------
# The icon is drawn in code, so it is sharp at every size and needs no image files.
$iconBlue = [Drawing.Color]::FromArgb(0, 103, 192)

# Broom on a blue rounded square. $tilt turns the broom (for the "cleaning" animation).
function New-WinSweepBitmap([int]$size, [single]$tilt = 35) {
    $bitmap = New-Object Drawing.Bitmap $size, $size
    $g = [Drawing.Graphics]::FromImage($bitmap)
    $g.SmoothingMode   = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $s = [single]$size

    $radius = $s * 0.22
    $square = New-Object Drawing.Drawing2D.GraphicsPath
    $square.AddArc(0, 0, 2 * $radius, 2 * $radius, 180, 90)
    $square.AddArc($s - 2 * $radius, 0, 2 * $radius, 2 * $radius, 270, 90)
    $square.AddArc($s - 2 * $radius, $s - 2 * $radius, 2 * $radius, 2 * $radius, 0, 90)
    $square.AddArc(0, $s - 2 * $radius, 2 * $radius, 2 * $radius, 90, 90)
    $square.CloseFigure()
    $blueBrush = New-Object Drawing.SolidBrush $iconBlue
    $g.FillPath($blueBrush, $square)

    # The broom is drawn upright in a 1x1 box around (0, 0), then scaled and turned.
    # It fills about 60% of the icon, and the offset centers the tilted broom.
    $scale = 0.70
    $g.TranslateTransform($s * (0.5 + 0.09 * $scale), $s * (0.5 - 0.07 * $scale))
    $g.RotateTransform($tilt)
    $g.ScaleTransform($s * $scale, $s * $scale)
    $white = [Drawing.Brushes]::White
    $handle = if ($size -lt 24) { 0.13 } else { 0.09 }   # thicker at tray size, so it stays visible
    $g.FillRectangle($white, [single](-$handle / 2), [single]-0.42, [single]$handle, [single]0.46)
    $g.FillRectangle($white, [single]-0.15, [single]0.02, [single]0.30, [single]0.08)     # band
    $bristles = [Drawing.PointF[]]@(
        (New-Object Drawing.PointF -0.15, 0.10), (New-Object Drawing.PointF 0.15, 0.10),
        (New-Object Drawing.PointF 0.25, 0.42), (New-Object Drawing.PointF -0.25, 0.42))
    $g.FillPolygon($white, $bristles)
    if ($size -ge 24) {
        $strand = New-Object Drawing.Pen $iconBlue, ([single]0.028)
        foreach ($x in -0.085, 0, 0.085) {
            $g.DrawLine($strand, [single]$x, [single]0.16, [single]($x * 1.5), [single]0.40)
        }
        $strand.Dispose()
    }
    $blueBrush.Dispose(); $square.Dispose(); $g.Dispose()
    $bitmap
}

# Writes a multi-size .ico file with PNG images (supported since Windows Vista).
function Save-IconFile([string]$path) {
    $sizes = 16, 20, 24, 32, 40, 48, 64, 256
    $images = foreach ($size in $sizes) {
        $bitmap = New-WinSweepBitmap $size
        $memory = New-Object IO.MemoryStream
        $bitmap.Save($memory, [Drawing.Imaging.ImageFormat]::Png)
        $bitmap.Dispose()
        , $memory.ToArray()
    }
    $writer = New-Object IO.BinaryWriter ([IO.File]::Create($path))
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $side = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }   # 0 means 256 in the ICO format
        $writer.Write([byte]$side); $writer.Write([byte]$side); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($image in $images) { $writer.Write($image) }
    $writer.Dispose()
}

if ($ExportIcon) { Save-IconFile $ExportIcon; return }

# --------------------------- Start-up ----------------------------
$appDir       = $PSScriptRoot
$uiScript     = Join-Path $appDir 'WinSweepUI.ps1'
$settingsFile = Join-Path $appDir 'settings.json'
$statusFile   = Join-Path $appDir 'status.json'

# The settings window asks for admin rights itself (UAC prompt).
function Open-Window {
    Start-Process powershell.exe -WindowStyle Hidden `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiScript`""
}

if ($Open) { Open-Window }

# One tray icon per signed-in user.
$firstInstance = $false
$instanceLock = New-Object Threading.Mutex($true, 'Local\WinSweepTray', [ref]$firstInstance)
if (-not $firstInstance) { return }

$nativeDll = Join-Path $appDir 'WinSweep.Native.dll'
if (Test-Path -LiteralPath $nativeDll) { Add-Type -Path $nativeDll }
else { Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $appDir 'WinSweepNative.cs') -Raw) }
# Sharp icon on scaled screens. Must run before any window is created.
[WinSweep.Native]::SetProcessDPIAware() | Out-Null
Add-Type -AssemblyName System.Windows.Forms
[Windows.Forms.Application]::EnableVisualStyles()

# Icons, made once. Handles are freed on exit.
$iconSize    = [Windows.Forms.SystemInformation]::SmallIconSize.Width
$iconHandles = New-Object System.Collections.Generic.List[IntPtr]
function New-TrayIcon([single]$tilt) {
    $bitmap = New-WinSweepBitmap $iconSize $tilt
    $handle = $bitmap.GetHicon()
    $bitmap.Dispose()
    $iconHandles.Add($handle)
    [Drawing.Icon]::FromHandle($handle)
}
$idleIcon  = New-TrayIcon 35
$busyIcons = @((New-TrayIcon 10), (New-TrayIcon 60))

# ----------------------------- State -----------------------------
$script:trayStarted   = Get-Date
$script:schedule      = [pscustomobject]@{ Enabled = $true; Day = 'Sunday'; Time = '12:00' }
$script:settingsStamp = [datetime]::MinValue
$script:lastRun       = $null                  # when the last cleanup ended
$script:statusStamp   = [datetime]::MinValue
$script:startedAt     = [datetime]::MinValue   # when this icon last started a cleanup
$script:scheduler     = $null
$script:frame         = 0

# Rereads settings.json and status.json only when they changed.
function Update-Files {
    $info = New-Object IO.FileInfo $settingsFile
    if ($info.Exists -and $info.LastWriteTimeUtc -ne $script:settingsStamp) {
        try {
            $saved = [IO.File]::ReadAllText($settingsFile) | ConvertFrom-Json
            $script:settingsStamp = $info.LastWriteTimeUtc
            $time = [datetime]::MinValue
            $script:schedule = [pscustomobject]@{
                Enabled = -not ("$($saved.Schedule.Enabled)" -eq 'False')
                Day     = if ("$($saved.Schedule.Day)" -in [Enum]::GetNames([DayOfWeek])) { "$($saved.Schedule.Day)" } else { 'Sunday' }
                Time    = if ([datetime]::TryParseExact("$($saved.Schedule.Time)", 'H:mm',
                              [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$time)) { $time.ToString('HH:mm') } else { '12:00' }
            }
        } catch { }   # being written; next tick
    }
    $info = New-Object IO.FileInfo $statusFile
    if ($info.Exists -and $info.LastWriteTimeUtc -ne $script:statusStamp) {
        try {
            $status = [IO.File]::ReadAllText($statusFile) | ConvertFrom-Json
            $script:statusStamp = $info.LastWriteTimeUtc
            $finished = "$($status.LastRun.Finished)"
            if ($finished) {
                $script:lastRun = [datetime]::Parse($finished, [Globalization.CultureInfo]::InvariantCulture, 'RoundtripKind').ToLocalTime()
            }
        } catch { }
    }
}

# The most recent scheduled time that is not in the future.
function Get-LastSlot {
    $now  = Get-Date
    $time = [datetime]::ParseExact($script:schedule.Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $slot = $now.Date.AddHours($time.Hour).AddMinutes($time.Minute)
    $slot = $slot.AddDays(-((7 + [int]$slot.DayOfWeek - [int][DayOfWeek]$script:schedule.Day) % 7))
    if ($slot -gt $now) { $slot = $slot.AddDays(-7) }
    $slot
}

# A cleanup is running while the cleaner holds its lock. Opening someone else's lock is not
# allowed for a normal user, which also means it exists.
function Test-Running {
    if ($script:startedAt -gt (Get-Date).AddSeconds(-30)) { return $true }   # the task is starting
    $lock = $null
    try {
        if ([Threading.Mutex]::TryOpenExisting('Global\WinSweep', [ref]$lock)) { $lock.Dispose(); return $true }
        return $false
    } catch [UnauthorizedAccessException] { return $true }
}

function Start-Cleanup {
    try {
        if (-not $script:scheduler) {
            $script:scheduler = New-Object -ComObject Schedule.Service
            $script:scheduler.Connect()
        }
        $script:scheduler.GetFolder('\WinSweep').GetTask('Cleanup').Run($null) | Out-Null
    } catch {
        $script:scheduler = $null   # connect again next time
    }
    # Set even when starting failed, so a failure is retried in an hour, not every minute.
    $script:startedAt = Get-Date
}

# Starts the scheduled cleanup when it is due: the last scheduled time is later than the last
# cleanup (or, if there has been none, later than the moment this icon started). Waits a few
# minutes after sign-in, so a missed cleanup doesn't slow down the start of the PC.
function Invoke-ScheduleCheck {
    if (-not $script:schedule.Enabled) { return }
    if ((Get-Date) -lt $script:trayStarted.AddMinutes(3)) { return }
    if ($script:startedAt -gt (Get-Date).AddHours(-1)) { return }
    if (Test-Running) { return }
    $slot = Get-LastSlot
    $since = if ($script:lastRun) { $script:lastRun } else { $script:trayStarted }
    if ($since -lt $slot) { Start-Cleanup }
}

function Get-NextText {
    if (-not $script:schedule.Enabled) { return 'automatic cleaning is off' }
    'next cleanup ' + (Get-LastSlot).AddDays(7).ToString('ddd HH:mm')
}

# ---------------------------- Tray icon --------------------------
$notify = New-Object Windows.Forms.NotifyIcon
$notify.Icon = $idleIcon
$notify.Text = 'WinSweep'
$notify.add_MouseClick({
    param($source, $e)
    if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Open-Window }
})

$menu = New-Object Windows.Forms.ContextMenuStrip
$openItem = New-Object Windows.Forms.ToolStripMenuItem 'Open WinSweep'
$openItem.Font = New-Object Drawing.Font $openItem.Font, ([Drawing.FontStyle]::Bold)
$openItem.add_Click({ Open-Window })
$closeItem = New-Object Windows.Forms.ToolStripMenuItem 'Close WinSweep'
$closeItem.ToolTipText = 'No automatic cleaning until you open WinSweep again'
$closeItem.add_Click({ Stop-Tray })
[void]$menu.Items.Add($openItem)
[void]$menu.Items.Add($closeItem)
$notify.ContextMenuStrip = $menu

function Update-Icon {
    if (Test-Running) {
        $notify.Text = 'WinSweep - cleaning now'
        if (-not $animation.Enabled) { $animation.Start() }
    } else {
        $animation.Stop()
        $notify.Icon = $idleIcon
        $notify.Text = 'WinSweep - ' + (Get-NextText)
    }
}

# The broom moves while a cleanup runs.
$animation = New-Object Windows.Forms.Timer
$animation.Interval = 400
$animation.add_Tick({
    $script:frame = 1 - $script:frame
    $notify.Icon = $busyIcons[$script:frame]
})

# Every 30 seconds: check the files' dates, whether a cleanup runs and whether one is due.
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 30000
$timer.add_Tick({
    Update-Files
    Invoke-ScheduleCheck
    Update-Icon
    # Check more often while cleaning, so the broom stops soon after the cleanup ends.
    $timer.Interval = if ($animation.Enabled) { 3000 } else { 30000 }
})

# Closing the icon ends this process: nothing of WinSweep keeps running.
function Stop-Tray {
    $timer.Stop(); $animation.Stop()
    $notify.Visible = $false
    $notify.Dispose()
    foreach ($handle in $iconHandles) { [WinSweep.Native]::DestroyIcon($handle) | Out-Null }
    [Windows.Forms.Application]::ExitThread()
}

Update-Files
Update-Icon
$notify.Visible = $true
$timer.Start()
[Windows.Forms.Application]::Run()
$instanceLock.ReleaseMutex()
