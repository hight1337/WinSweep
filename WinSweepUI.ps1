<#
.SYNOPSIS
    Settings window for WinSweep.

.DESCRIPTION
    Turn cleanup steps on or off, change the schedule, preview a cleanup, run one now and
    read the logs. "Save changes" writes settings.json next to WinSweep.ps1; the tray icon
    reads the schedule from there. Preview and Clean now use the choices on screen without
    saving them.

    The window asks for admin rights (UAC prompt), because cleaning system folders and
    changing settings that the cleaner uses with admin rights need them.
#>

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# Restart with admin rights if needed.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ErrorAction Stop `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    } catch {
        [Windows.MessageBox]::Show(
            "WinSweep needs admin rights to clean system folders and change its settings.`n`nOpen it again and click Yes when Windows asks.",
            'WinSweep', 'OK', 'Information') | Out-Null
    }
    exit
}

$appDir       = $PSScriptRoot
$cleaner      = Join-Path $appDir 'WinSweep.ps1'
$settingsFile = Join-Path $appDir 'settings.json'
$statusFile   = Join-Path $appDir 'status.json'
$logDir       = Join-Path $appDir 'logs'
$runDir       = Join-Path $appDir 'run'   # files for a running preview or cleanup; admin-only, like the whole folder
$iconFile     = Join-Path $appDir 'WinSweep.ico'

# One window at a time, so two windows can't overwrite each other's changes.
$firstWindow = $false
$windowLock = New-Object Threading.Mutex($true, 'Local\WinSweepWindow', [ref]$firstWindow)
if (-not $firstWindow) {
    [Windows.MessageBox]::Show('WinSweep is already open.', 'WinSweep', 'OK', 'Information') | Out-Null
    exit
}

# Sharp text on scaled screens. Must run before the window is created.
$nativeDll = Join-Path $appDir 'WinSweep.Native.dll'
if (Test-Path -LiteralPath $nativeDll) { Add-Type -Path $nativeDll }
else { Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $appDir 'WinSweepNative.cs') -Raw) }
[WinSweep.Native]::SetProcessDPIAware() | Out-Null
$dayNames     = 'Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'
$maxOutputLines = 2000

# Short explanation under each step. Step names come from WinSweep.ps1.
$stepHints = @{
    UserTemp             = 'Installer leftovers and app scratch files'
    WindowsTemp          = 'Leftovers from Windows and services'
    CrashDumps           = 'Saved when an app or Windows crashes'
    UpdateDownloads      = 'Downloaded update files. Skipped while an update waits for a restart'
    DeliveryOptimization = 'Update files kept to share with other PCs'
    RecycleBin           = 'Only items deleted longer ago than the days set in Options'
    ComponentCleanup     = 'Old system files replaced by updates. Slow: 5-30 min'
}

[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="WinSweep" Width="880" Height="880" MinWidth="780" MinHeight="600"
        WindowStartupLocation="CenterScreen" Background="#F3F3F3"
        FontFamily="Segoe UI" FontSize="13" Foreground="#1B1B1B">
  <Window.Resources>
    <Style x:Key="Card" TargetType="Border">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="BorderBrush" Value="#E5E5E5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CornerRadius" Value="8"/>
      <Setter Property="Padding" Value="18,14"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
    </Style>
    <Style x:Key="Heading" TargetType="TextBlock">
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Margin" Value="0,0,0,6"/>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#616161"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Margin" Value="0,8,0,0"/>
      <Setter Property="VerticalContentAlignment" Value="Top"/>
    </Style>
    <Style TargetType="TextBox">
      <Setter Property="Padding" Value="4,3"/>
      <Setter Property="BorderBrush" Value="#C8C8C8"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style x:Key="Number" TargetType="TextBox" BasedOn="{StaticResource {x:Type TextBox}}">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Margin" Value="6,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#FFFFFF"/>
      <Setter Property="Foreground" Value="#1B1B1B"/>
      <Setter Property="BorderBrush" Value="#C8C8C8"/>
      <Setter Property="Padding" Value="16,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="ToolTipService.ShowOnDisabled" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Box" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="5" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Box" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Box" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Primary" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
      <Setter Property="Background" Value="#0067C0"/>
      <Setter Property="BorderBrush" Value="#0067C0"/>
      <Setter Property="Foreground" Value="#FFFFFF"/>
    </Style>
  </Window.Resources>

  <Grid Margin="20,16,20,20">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,14">
      <StackPanel Orientation="Horizontal">
        <TextBlock Text="WinSweep" FontSize="24" FontWeight="SemiBold"/>
        <TextBlock x:Name="VersionText" Style="{StaticResource Hint}" VerticalAlignment="Bottom" Margin="8,0,0,5"/>
      </StackPanel>
      <TextBlock Style="{StaticResource Hint}" Margin="0,2,0,0"
                 Text="Deletes temp and junk files, automatically on a schedule or whenever you want. Recent files and files in use are left alone."/>
    </StackPanel>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="12"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Style="{StaticResource Card}">
        <StackPanel>
          <TextBlock Text="What to clean" Style="{StaticResource Heading}"/>
          <StackPanel x:Name="StepsPanel"/>
        </StackPanel>
      </Border>

      <StackPanel Grid.Column="2">
        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Schedule" Style="{StaticResource Heading}"/>
            <CheckBox x:Name="ScheduleOn" Content="Clean automatically" Margin="0,2,0,0"/>
            <StackPanel Orientation="Horizontal" Margin="0,10,0,0">
              <TextBlock Text="Every" VerticalAlignment="Center"/>
              <ComboBox x:Name="DayBox" Width="120" Margin="8,0" Padding="6,4"/>
              <TextBlock Text="at" VerticalAlignment="Center"/>
              <TextBox x:Name="TimeBox" Width="60" Margin="8,0" HorizontalContentAlignment="Center"
                       ToolTip="24-hour time, for example 12:00 or 18:30"/>
            </StackPanel>
            <TextBlock Style="{StaticResource Hint}" Margin="0,8,0,0" FontSize="12"
                       Text="Runs while the WinSweep icon is next to the clock. The icon starts at sign-in only while this is on. If the PC was off at that time, it runs a few minutes after you sign in."/>
            <TextBlock x:Name="NextRunText" Margin="0,10,0,0"/>
            <TextBlock x:Name="LastRunText" Margin="0,4,0,0"/>
          </StackPanel>
        </Border>

        <Border Style="{StaticResource Card}">
          <StackPanel>
            <TextBlock Text="Options" Style="{StaticResource Heading}"/>
            <StackPanel Orientation="Horizontal" Margin="0,4,0,0">
              <TextBlock Text="Keep files created or changed in the last" VerticalAlignment="Center"/>
              <TextBox x:Name="DaysBox" Style="{StaticResource Number}"/>
              <TextBlock Text="days" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <TextBlock Text="Recycle Bin: remove items older than" VerticalAlignment="Center"/>
              <TextBox x:Name="BinDaysBox" Style="{StaticResource Number}"/>
              <TextBlock Text="days" VerticalAlignment="Center"/>
            </StackPanel>
            <StackPanel Orientation="Horizontal" Margin="0,8,0,0">
              <TextBlock Text="Keep the last" VerticalAlignment="Center"/>
              <TextBox x:Name="KeepLogsBox" Style="{StaticResource Number}"/>
              <TextBlock Text="cleanup logs" VerticalAlignment="Center"/>
            </StackPanel>
            <CheckBox x:Name="ListFilesBox" Content="List every deleted file in the log" Margin="0,10,0,0"/>
          </StackPanel>
        </Border>
      </StackPanel>
    </Grid>

    <DockPanel Grid.Row="2" Margin="0,0,0,10" LastChildFill="True">
      <Button x:Name="SaveButton" Content="Save changes" Style="{StaticResource Primary}"
              />
      <Button x:Name="PreviewButton" Content="Preview"
              ToolTip="Show what would be deleted. Nothing is deleted. Uses the choices on screen."/>
      <Button x:Name="CleanButton" Content="Clean now"
              ToolTip="Delete the selected junk files now. Uses the choices on screen."/>
      <Button x:Name="StopButton" Content="Stop" Visibility="Collapsed"/>
      <Button x:Name="LogsButton" Content="Open logs folder"/>
      <TextBlock x:Name="StatusText" Style="{StaticResource Hint}" VerticalAlignment="Center" Margin="8,0,0,0"/>
    </DockPanel>

    <Border Grid.Row="3" x:Name="ProgressCard" Style="{StaticResource Card}" Margin="0,0,0,10" Visibility="Collapsed">
      <StackPanel>
        <DockPanel>
          <TextBlock x:Name="ProgressPercent" DockPanel.Dock="Right" FontWeight="SemiBold"/>
          <TextBlock x:Name="ProgressTitle" FontWeight="SemiBold"/>
        </DockPanel>
        <ProgressBar x:Name="ProgressBar" Height="6" Margin="0,8,0,8" Minimum="0" Maximum="100"
                     Foreground="#0067C0" Background="#E5E5E5" BorderThickness="0"/>
        <TextBlock x:Name="ProgressDetail" Style="{StaticResource Hint}" TextWrapping="NoWrap" TextTrimming="CharacterEllipsis"/>
      </StackPanel>
    </Border>

    <DockPanel Grid.Row="4">
      <TextBlock x:Name="OutputTitle" DockPanel.Dock="Top" FontWeight="SemiBold" Margin="2,0,0,6"/>
      <TextBox x:Name="Output" IsReadOnly="True" FontFamily="Consolas" FontSize="12" MinHeight="80"
               Background="#FFFFFF" BorderBrush="#E5E5E5" Padding="8" TextWrapping="NoWrap" VerticalContentAlignment="Top"
               VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
    </DockPanel>
  </Grid>
</Window>
'@

$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($name in 'StepsPanel', 'ScheduleOn', 'DayBox', 'TimeBox', 'NextRunText', 'LastRunText', 'DaysBox',
                  'BinDaysBox', 'KeepLogsBox', 'ListFilesBox', 'SaveButton', 'PreviewButton', 'CleanButton',
                  'StopButton', 'LogsButton', 'StatusText', 'ProgressCard', 'ProgressTitle', 'ProgressPercent',
                  'ProgressBar', 'ProgressDetail', 'OutputTitle', 'Output') {
    Set-Variable -Name $name -Value $window.FindName($name)
}
# Fit small or scaled screens.
$window.Height = [math]::Min($window.Height, [Windows.SystemParameters]::WorkArea.Height - 20)

$brushes   = New-Object System.Windows.Media.BrushConverter
$hintBrush = $brushes.ConvertFromString('#616161')
$warnBrush = $brushes.ConvertFromString('#9D5D00')

# ----------------------------- State -----------------------------
$script:loading    = $true    # true while controls are filled from saved settings
$script:dirty      = $false   # unsaved changes on screen
$script:busy       = $false   # a cleanup or preview is running
$script:lastStatus = ''

$initial = (& $cleaner -ShowSettings) -join "`n" | ConvertFrom-Json
$window.FindName('VersionText').Text = "version $($initial.Version)"
$window.Title = "WinSweep $($initial.Version)"

$stepBoxes = [ordered]@{}
foreach ($step in $initial.Steps.PSObject.Properties.Name) {
    $text = New-Object System.Windows.Controls.StackPanel
    $text.Margin = [Windows.Thickness]::new(4, -1, 0, 0)
    $text.Children.Add((New-Object System.Windows.Controls.TextBlock -Property @{ Text = $initial.Labels.$step })) | Out-Null
    $text.Children.Add((New-Object System.Windows.Controls.TextBlock -Property @{
        Text = $stepHints[$step]; FontSize = 12; Foreground = $hintBrush; TextWrapping = 'Wrap' })) | Out-Null
    $box = New-Object System.Windows.Controls.CheckBox
    $box.Content = $text
    $box.Add_Click({ Set-Dirty })
    $StepsPanel.Children.Add($box) | Out-Null
    $stepBoxes[$step] = $box
}
$dayNames | ForEach-Object { $DayBox.Items.Add($_) | Out-Null }

# --------------------------- Helpers -----------------------------
function Show-Error([string]$message) {
    [Windows.MessageBox]::Show($window, $message, 'WinSweep', 'OK', 'Warning') | Out-Null
}

function Update-Controls {
    $anyStep = @($stepBoxes.Values | Where-Object { $_.IsChecked }).Count -gt 0
    $SaveButton.IsEnabled    = -not $script:busy -and $script:dirty
    $PreviewButton.IsEnabled = -not $script:busy -and $anyStep
    $CleanButton.IsEnabled   = -not $script:busy -and $anyStep
    $StopButton.Visibility   = if ($script:busy) { 'Visible' } else { 'Collapsed' }
    $DayBox.IsEnabled        = [bool]$ScheduleOn.IsChecked
    $TimeBox.IsEnabled       = [bool]$ScheduleOn.IsChecked
    $SaveButton.ToolTip      = if ($script:dirty) { 'Save your changes to what gets cleaned and to the schedule' } else { 'Nothing to save: change a setting first' }
    if ($anyStep) { $PreviewButton.ToolTip = 'Show what would be deleted. Nothing is deleted. Uses the choices on screen.' }
    else { $PreviewButton.ToolTip = 'Tick at least one item under What to clean.' }
    $CleanButton.ToolTip = if ($anyStep) { 'Delete the selected junk files now. Uses the choices on screen.' } else { $PreviewButton.ToolTip }

    if ($script:busy) { return }
    if ($script:dirty) { $StatusText.Text = 'Unsaved changes'; $StatusText.Foreground = $warnBrush }
    else { $StatusText.Text = $script:lastStatus; $StatusText.Foreground = $hintBrush }
}

function Set-Dirty {
    if ($script:loading) { return }
    $script:dirty = $true
    Update-Controls
}

function Read-Number($box, [string]$label, [int]$min, [int]$max) {
    $number = 0
    if (-not [int]::TryParse($box.Text.Trim(), [ref]$number) -or $number -lt $min -or $number -gt $max) {
        throw "$label must be a whole number from $min to $max."
    }
    $number
}

function Import-Settings($settings) {
    foreach ($step in $stepBoxes.Keys) { $stepBoxes[$step].IsChecked = [bool]$settings.Steps.$step }
    $DaysBox.Text           = $settings.DaysOld
    $BinDaysBox.Text        = $settings.RecycleBinDays
    $KeepLogsBox.Text       = $settings.KeepLogs
    $ListFilesBox.IsChecked = [bool]$settings.ListFiles
}

function Read-Time {
    $time = [datetime]::MinValue
    if (-not [datetime]::TryParseExact($TimeBox.Text.Trim(), 'H:mm', [Globalization.CultureInfo]::InvariantCulture,
                                       'None', [ref]$time)) {
        throw 'Time must be in 24-hour format, for example 12:00 or 18:30.'
    }
    $time.ToString('HH:mm')
}

# Writes the choices on screen to a settings file. Throws with a clear message on bad input.
function Write-SettingsFile([string]$path) {
    $settings = [ordered]@{
        Steps          = [ordered]@{}
        DaysOld        = Read-Number $DaysBox 'Days to keep recent files' 1 365
        RecycleBinDays = Read-Number $BinDaysBox 'Recycle Bin days' 1 3650
        ListFiles      = [bool]$ListFilesBox.IsChecked
        KeepLogs       = Read-Number $KeepLogsBox 'Number of cleanup logs' 1 1000
        Schedule       = [ordered]@{
            Enabled = [bool]$ScheduleOn.IsChecked
            Day     = $dayNames[$DayBox.SelectedIndex]
            Time    = Read-Time
        }
    }
    foreach ($step in $stepBoxes.Keys) { $settings.Steps[$step] = [bool]$stepBoxes[$step].IsChecked }
    $settings | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding UTF8
}

function Import-Schedule($schedule) {
    $ScheduleOn.IsChecked = [bool]$schedule.Enabled
    $DayBox.SelectedIndex = [array]::IndexOf($dayNames, "$($schedule.Day)")
    $TimeBox.Text         = $schedule.Time
}

function Test-TrayRunning {
    [bool](Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*WinSweepTray.ps1*' })
}

# The tray icon runs, and starts at sign-in, only while automatic cleaning is on. Turning it off
# removes the startup entry (the icon closes itself within half a minute). Turning it on adds the
# entry and starts the icon. Only for the installed copy, not when run from the source folder.
function Update-Startup([bool]$on) {
    if ($appDir -ne (Join-Path $env:ProgramData 'WinSweep')) { return $false }
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if (-not $on) {
        Remove-ItemProperty -Path $runKey -Name 'WinSweep' -ErrorAction SilentlyContinue
        return $false
    }
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Set-ItemProperty -Path $runKey -Name 'WinSweep' `
        -Value "`"$powershell`" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $appDir 'WinSweepTray.ps1')`""
    $trayShortcut = Join-Path $appDir 'Start tray icon.lnk'   # made by the installer
    if ((Test-TrayRunning) -or -not (Test-Path -LiteralPath $trayShortcut)) { return $false }
    # This window runs with admin rights. Explorer starts the icon as the signed-in user instead.
    Start-Process explorer.exe -ArgumentList "`"$trayShortcut`""
    $true
}

# The next scheduled time, from the saved settings (the tray icon uses the same rule).
function Show-NextRun([switch]$TrayStarting) {
    $schedule = ((& $cleaner -ShowSettings) -join "`n" | ConvertFrom-Json).Schedule
    if (-not $schedule.Enabled) {
        $NextRunText.Text = "Next run: off. WinSweep doesn't start by itself; open it from the Start menu when you need it."
        return
    }
    if (-not $TrayStarting -and -not (Test-TrayRunning)) {
        $NextRunText.Text = 'Next run: none, because the WinSweep icon is closed. It starts again at your next sign-in, or when you open WinSweep from the Start menu.'
        return
    }
    $time = [datetime]::ParseExact($schedule.Time, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
    $next = (Get-Date).Date.AddHours($time.Hour).AddMinutes($time.Minute)
    $next = $next.AddDays((7 + [int][DayOfWeek]$schedule.Day - [int]$next.DayOfWeek) % 7)
    if ($next -le (Get-Date)) { $next = $next.AddDays(7) }
    $NextRunText.Text = 'Next run: ' + $next.ToString('dddd, d MMM yyyy, HH:mm')
}

function Save-All {
    Write-SettingsFile $settingsFile
    $trayStarting = Update-Startup ([bool]$ScheduleOn.IsChecked)
    $script:dirty = $false
    $script:lastStatus = 'Changes saved at ' + (Get-Date).ToString('HH:mm') + '.'
    Update-Controls
    Show-NextRun -TrayStarting:$trayStarting
}
# Newest cleanup log: the file and its last lines (enough for the output box).
function Read-LastLog {
    $file = Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if (-not $file) { return $null }
    [pscustomobject]@{ File = $file; Lines = @(Get-Content -LiteralPath $file.FullName -Encoding UTF8 -Tail $maxOutputLines) }
}

function Show-LastRun($last) {
    if (-not $last) { $LastRunText.Text = 'Last run: never'; return }
    $done = $last.Lines | Where-Object { $_ -match '  Done\. ' } | Select-Object -Last 1
    $result = if ($done -match 'Freed (\S+ [MG]B)') { ', freed ' + $Matches[1] } elseif (-not $done) { ' (did not finish)' } else { '' }
    $LastRunText.Text = 'Last run: ' + $last.File.LastWriteTime.ToString('d MMM yyyy, HH:mm') + $result
}

# Appends lines to the output box and keeps it at most about $maxOutputLines lines,
# so a long file list does not slow the window down.
$script:outputLines = 0
function Add-Output([string]$text, [int]$lineCount) {
    $Output.AppendText($text)
    $script:outputLines += $lineCount
    if ($script:outputLines -gt $maxOutputLines * 1.5) {
        $keep = ($Output.Text -split "`r`n") | Select-Object -Last $maxOutputLines
        $Output.Text = "(Older lines are hidden here.)`r`n" + ($keep -join "`r`n")
        $script:outputLines = $maxOutputLines
    }
    $Output.ScrollToEnd()
}

function Set-ProgressView([string]$title, [string]$detail, [double]$percent) {
    $ProgressCard.Visibility = 'Visible'
    $ProgressTitle.Text  = $title
    $ProgressDetail.Text = $detail
    if ($percent -lt 0) {
        $ProgressBar.IsIndeterminate = $true
    } else {
        $ProgressBar.IsIndeterminate = $false
        $ProgressBar.Value = [math]::Min(100, $percent)
        $ProgressPercent.Text = '{0:N0}%' -f $ProgressBar.Value
    }
}

# Line format from WinSweep.ps1: "@progress|step number|step count|step name|fraction|detail".
# Fraction -1 means the step does not know how far along it is yet.
function Show-ProgressLine([string]$line) {
    $parts = $line -split '\|', 6
    $number = [int]$parts[1]; $count = [math]::Max(1, [int]$parts[2])
    $fraction = [double]::Parse($parts[4], [Globalization.CultureInfo]::InvariantCulture)
    if ($fraction -lt 0) {
        $ProgressPercent.Text = '{0:N0}%' -f (($number - 1) / $count * 100)
        $percent = -1
    } else {
        $percent = (($number - 1) + $fraction) / $count * 100
    }
    Set-ProgressView "Step $number of ${count}: $($parts[3])" $parts[5] $percent
}

# ------------------------- Running a cleanup -------------------------
# A cleanup runs in a separate hidden PowerShell process with a temporary settings file
# (the choices on screen). It writes log and progress lines to a live log file; a timer
# reads new complete lines, sends log lines to the output box and shows the latest progress.
$script:process     = $null
$script:reader      = $null
$script:liveLog     = $null
$script:runSettings = $null
$script:dryRun      = $false
$script:stopped     = $false
$script:pending     = ''
$script:doneLine    = $null
$script:lastLine    = $null

function Remove-RunFiles {
    if ($script:reader) { $script:reader.Dispose(); $script:reader = $null }
    foreach ($path in $script:liveLog, $script:runSettings) {
        if ($path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
    }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $exited = $script:process.HasExited
    if (-not $script:reader -and (Test-Path -LiteralPath $script:liveLog)) {
        $stream = New-Object IO.FileStream($script:liveLog, 'Open', 'Read', 'ReadWrite')
        $script:reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
    }
    if ($script:reader) {
        $script:pending += $script:reader.ReadToEnd()
        $cut = $script:pending.LastIndexOf("`n")
        if ($cut -ge 0) {
            $complete = $script:pending.Substring(0, $cut)
            $script:pending = $script:pending.Substring($cut + 1)
            $logText = New-Object Text.StringBuilder
            $logLines = 0
            $progress = $null
            foreach ($line in $complete -split "`r?`n") {
                if (-not $line) { continue }
                if ($line.StartsWith('@progress|')) { $progress = $line; continue }
                if ($line -match '  Done\. ') { $script:doneLine = $line -replace '^.*?  Done\.\s*', '' }
                $script:lastLine = $line -replace '^\S+ \S+  ', ''
                [void]$logText.AppendLine($line); $logLines++
            }
            if ($logLines) { Add-Output $logText.ToString() $logLines }
            if ($progress) { Show-ProgressLine $progress }
        }
    }
    if (-not $exited) { return }

    $timer.Stop()
    Remove-RunFiles
    $what = if ($script:dryRun) { 'Preview' } else { 'Cleanup' }
    if ($script:stopped) {
        $detail = if ($script:dryRun) { 'The preview was stopped.' }
                  else { 'Files deleted before the stop stay deleted. The log shows what was removed.' }
        Set-ProgressView "$what stopped" $detail $ProgressBar.Value
        $script:lastStatus = "$what stopped."
    } elseif ($script:doneLine) {
        Set-ProgressView "$what finished" $script:doneLine 100
        $script:lastStatus = if ($script:dryRun) { 'Preview finished. Nothing was deleted.' } else { 'Cleanup finished.' }
    } else {
        $detail = if ($script:lastLine) { $script:lastLine } else { 'The cleaner closed unexpectedly.' }
        Set-ProgressView "$what could not finish" $detail $ProgressBar.Value
        $script:lastStatus = "$what could not finish."
    }
    $script:busy = $false
    Update-Controls
    Show-LastRun (Read-LastLog)
    Show-NextRun
})

function Start-Cleaner([bool]$dryRun) {
    # Run files go in the program folder, not in the user's temp folder: only admins can
    # change them there, so nothing else can swap the settings the cleaner will use.
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $id = [guid]::NewGuid().ToString('N')
    $script:runSettings = Join-Path $runDir "settings-$id.json"
    try { Write-SettingsFile $script:runSettings } catch { Show-Error $_.Exception.Message; return }
    $script:liveLog  = Join-Path $runDir "live-$id.log"
    $script:dryRun   = $dryRun
    $script:stopped  = $false
    $script:pending  = ''
    $script:doneLine = $null
    $script:lastLine = $null
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$cleaner`" -SettingsFile `"$($script:runSettings)`" -LiveLog `"$($script:liveLog)`""
    if ($dryRun) { $arguments += ' -DryRun' }

    $Output.Clear(); $script:outputLines = 0
    $OutputTitle.Text = if ($dryRun) { 'Preview log' } else { 'Cleanup log' }
    $ProgressPercent.Text = '0%'
    Set-ProgressView $(if ($dryRun) { 'Preview' } else { 'Cleaning' }) 'Starting...' 0
    $script:busy = $true
    Update-Controls
    $StatusText.Text = if ($dryRun) { 'Preview running. Nothing is deleted.' } else { 'Cleaning...' }
    $StatusText.Foreground = $hintBrush
    $script:process = Start-Process powershell.exe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    $timer.Start()
}

# Stops the cleaner process only. A running DISM step finishes on its own in the background,
# because stopping DISM halfway is not safe.
function Stop-Cleaner {
    if ($script:process -and -not $script:process.HasExited) {
        $script:stopped = $true
        Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue
        if (-not $script:dryRun) { Write-StoppedStatus }
    }
}

# Records a stopped cleanup in status.json, so the tray icon does not start it again right away.
function Write-StoppedStatus {
    try {
        $status = Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json
        $status.Running = $false
        $status.LastRun = [ordered]@{ Finished = (Get-Date).ToString('o'); Result = 'stopped'; Message = 'Stopped in the settings window' }
        $status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $statusFile -Encoding UTF8
    } catch { }
}

# --------------------------- Events ------------------------------
foreach ($box in $DaysBox, $BinDaysBox, $KeepLogsBox, $TimeBox) { $box.Add_TextChanged({ Set-Dirty }) }
$ListFilesBox.Add_Click({ Set-Dirty })
$DayBox.Add_SelectionChanged({ Set-Dirty })
$ScheduleOn.Add_Click({ Set-Dirty })

$SaveButton.Add_Click({ try { Save-All } catch { Show-Error $_.Exception.Message } })
$PreviewButton.Add_Click({ Start-Cleaner $true })
$CleanButton.Add_Click({
    $answer = [Windows.MessageBox]::Show($window, "Clean up the selected junk files now?`n`nRecent files and files in use are left alone.", 'WinSweep', 'YesNo')
    if ($answer -eq 'Yes') { Start-Cleaner $false }
})
$StopButton.Add_Click({ Stop-Cleaner })
$LogsButton.Add_Click({
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    Start-Process explorer.exe $logDir
})

$window.Add_Closing({
    param($source, $e)
    if ($script:busy) {
        $answer = [Windows.MessageBox]::Show($window, 'A cleanup is still running. Stop it and close?', 'WinSweep', 'YesNo', 'Question')
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-Cleaner
    } elseif ($script:dirty) {
        $answer = [Windows.MessageBox]::Show($window, 'Save your changes before closing?', 'WinSweep', 'YesNoCancel', 'Question')
        if ($answer -eq 'Cancel') { $e.Cancel = $true; return }
        if ($answer -eq 'Yes') {
            try { Save-All } catch { Show-Error $_.Exception.Message; $e.Cancel = $true; return }
        }
    }
    $timer.Stop()
    Remove-RunFiles
})

# --------------------------- Start -------------------------------
Import-Settings $initial
Import-Schedule $initial.Schedule
$script:loading = $false
Update-Controls
Show-NextRun

$last = Read-LastLog
Show-LastRun $last
if ($last) {
    $OutputTitle.Text = 'Last cleanup log (' + $last.File.LastWriteTime.ToString('d MMM yyyy, HH:mm') + ')'
    $Output.Text = $last.Lines -join "`r`n"
    $script:outputLines = $last.Lines.Count
} else {
    $OutputTitle.Text = 'Log'
    $Output.Text = 'No cleanup has run yet. Click Preview to see what would be deleted.'
}

if (Test-Path -LiteralPath $iconFile) {
    $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object Uri $iconFile))
}

$window.ShowDialog() | Out-Null
