<#
.SYNOPSIS
    Installs WinSweep, or updates an existing install.

.DESCRIPTION
    - Creates C:\ProgramData\WinSweep so that only admins can change it, then copies the scripts
      there and builds WinSweep.Native.dll from WinSweepNative.cs.
    - Creates the "WinSweep\Cleanup" scheduled task. It has no schedule of its own: it runs
      WinSweep.ps1 as SYSTEM when the tray icon starts it. Signed-in users may start it and read
      its status, not change it.
    - Starts the tray icon at every sign-in while automatic cleaning is on. While the icon runs,
      WinSweep cleans on the schedule set in the settings window (-Day and -At on a first
      install; Sunday 12:00 by default).
    - Adds the "WinSweep" Start menu shortcut, which opens the window (and starts the icon if
      automatic cleaning is on).

    When WinSweep is already installed, its settings, logs and schedule are kept, unless -Day or
    -At is given. To remove everything, run Uninstall.cmd.

.PARAMETER Quiet
    Do not show the "Installed" message at the end.
#>
param(
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$Day = 'Sunday',
    [string]$At = '12:00',
    [switch]$Quiet,
    [switch]$FromLauncher   # set by the first, non-admin copy of this script, which then starts the tray icon
)

Add-Type -AssemblyName PresentationFramework

$dayGiven   = $PSBoundParameters.ContainsKey('Day')
$atGiven    = $PSBoundParameters.ContainsKey('At')
$installDir = Join-Path $env:ProgramData 'WinSweep'
$trayPath   = Join-Path $installDir 'WinSweepTray.ps1'
$trayArgs   = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$trayPath`""

# Restart with admin rights if needed. This first copy runs as the signed-in user, so after
# the install it starts the tray icon without admin rights.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -FromLauncher"
    if ($dayGiven) { $arguments += " -Day $Day" }
    if ($atGiven)  { $arguments += " -At `"$At`"" }
    if ($Quiet) { $arguments += ' -Quiet' }
    try {
        $admin = Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -Wait -PassThru -ErrorAction Stop
        if ($admin.ExitCode -eq 0 -and (Test-Path -LiteralPath $trayPath)) {
            Start-Process powershell.exe -ArgumentList $trayArgs -WindowStyle Hidden
        }
    } catch {
        [Windows.MessageBox]::Show('WinSweep was not installed, because admin permission was not given.',
            'WinSweep', 'OK', 'Information') | Out-Null
    }
    exit
}

function Get-WinSweepProcesses([string]$script) {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*$script*" }
}

# Only admins and SYSTEM may change the program folder, because SYSTEM runs code from it.
# Any user can create folders in C:\ProgramData, so a folder that someone else created or
# changed is moved aside, and the permissions are set from scratch before anything is copied.
function Initialize-InstallFolder([string]$path) {
    $system = New-Object Security.Principal.SecurityIdentifier 'S-1-5-18'
    $admins = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $users  = New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-545'

    if (Test-Path -LiteralPath $path) {
        $item  = Get-Item -LiteralPath $path -Force
        $owner = (Get-Acl -LiteralPath $path).GetOwner([Security.Principal.SecurityIdentifier])
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or ($owner -ne $admins -and $owner -ne $system)) {
            Rename-Item -LiteralPath $path -NewName ('WinSweep.untrusted-{0:yyyyMMdd-HHmmss}' -f (Get-Date))
        }
    }
    New-Item -ItemType Directory -Path $path -Force | Out-Null

    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)   # no inherited rules
    $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    foreach ($rule in @(@($system, 'FullControl'), @($admins, 'FullControl'), @($users, 'ReadAndExecute'))) {
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule $rule[0], $rule[1], $inherit, 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $path -AclObject $acl
    # Existing files and folders inside: owner Administrators, only the rules above.
    & icacls.exe $path /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set the owner of $path." }
    & icacls.exe "$path\*" /reset /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set permissions in $path." }
}

# Moves the schedule of older versions (a trigger on the task) into settings.json, and applies
# -Day and -At when they are given. Existing settings are kept.
function Set-Schedule([string]$settingsFile, $oldTrigger, [bool]$oldEnabled) {
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $settingsFile) {
        $saved = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json
        foreach ($property in $saved.PSObject.Properties) { $settings[$property.Name] = $property.Value }
    }
    $schedule = [ordered]@{ Enabled = $true; Day = $Day; Time = $At }
    if ($settings.Schedule) {
        $schedule = [ordered]@{ Enabled = $settings.Schedule.Enabled; Day = $settings.Schedule.Day; Time = $settings.Schedule.Time }
    } elseif ($oldTrigger) {
        $dayIndex = 0..6 | Where-Object { [int]$oldTrigger.DaysOfWeek -band (1 -shl $_) } | Select-Object -First 1
        if ($null -ne $dayIndex) { $schedule.Day = ([DayOfWeek]$dayIndex).ToString() }
        $schedule.Time    = ([datetime]$oldTrigger.StartBoundary).ToString('HH:mm')
        $schedule.Enabled = $oldEnabled
    }
    if ($dayGiven) { $schedule.Day = $Day }
    if ($atGiven) {
        $schedule.Time = ([datetime]::ParseExact($At, 'H:mm', [Globalization.CultureInfo]::InvariantCulture)).ToString('HH:mm')
    }
    $settings.Schedule = $schedule
    $settings | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $settingsFile -Encoding UTF8
    $schedule
}

$ErrorActionPreference = 'Stop'
try {
    if (Get-WinSweepProcesses 'WinSweepUI.ps1') { throw 'The WinSweep window is open. Close it and run Install.cmd again.' }

    # Schedule of older versions: a trigger on the task "\WinSweep" (1.0) or "\WinSweep\Cleanup".
    $old = Get-ScheduledTask -TaskPath '\WinSweep\' -TaskName 'Cleanup' -ErrorAction SilentlyContinue
    if (-not $old) { $old = Get-ScheduledTask -TaskPath '\' -TaskName 'WinSweep' -ErrorAction SilentlyContinue }
    $oldTrigger = $old.Triggers | Where-Object { $_.StartBoundary } | Select-Object -First 1
    $oldEnabled = -not ($old -and ($old.State -eq 'Disabled' -or ($oldTrigger -and -not $oldTrigger.Enabled)))

    Get-WinSweepProcesses 'WinSweepTray.ps1' | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Initialize-InstallFolder $installDir
    foreach ($file in 'WinSweep.ps1', 'WinSweepUI.ps1', 'WinSweepTray.ps1') {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination (Join-Path $installDir $file) -Force
    }
    $dll = Join-Path $installDir 'WinSweep.Native.dll'
    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force }
    Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'WinSweepNative.cs') -Raw) `
        -OutputAssembly $dll -OutputType Library
    & $trayPath -ExportIcon (Join-Path $installDir 'WinSweep.ico')
    $schedule = Set-Schedule (Join-Path $installDir 'settings.json') $oldTrigger $oldEnabled

    # ---- Scheduled task: runs the cleaner as SYSTEM when the tray icon starts it
    foreach ($task in @(@('\', 'WinSweep'), @('\WinSweep\', 'Cleanup'), @('\WinSweep\', 'Settings'), @('\WinSweep\', 'Preview'))) {
        Unregister-ScheduledTask -TaskPath $task[0] -TaskName $task[1] -Confirm:$false -ErrorAction SilentlyContinue
    }
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$(Join-Path $installDir 'WinSweep.ps1')`""
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                     -ExecutionTimeLimit (New-TimeSpan -Hours 2) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskPath '\WinSweep\' -TaskName 'Cleanup' -Action $action -Settings $settings `
        -Principal $principal -Force -Description 'Deletes temp and junk files. Started by the WinSweep tray icon.' | Out-Null
    # SYSTEM and admins: full control. Signed-in users: start it and read its status.
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $scheduler.GetFolder('\WinSweep').GetTask('Cleanup').SetSecurityDescriptor('D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)', 0)

    # ---- Tray icon at every sign-in, only while automatic cleaning is on. The settings window
    # adds or removes this entry when the schedule is switched on or off.
    $powershell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $runKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
    if ($schedule.Enabled) { Set-ItemProperty -Path $runKey -Name 'WinSweep' -Value "`"$powershell`" $trayArgs" }
    else { Remove-ItemProperty -Path $runKey -Name 'WinSweep' -ErrorAction SilentlyContinue }

    # ---- Shortcut the settings window uses to start the tray icon without admin rights
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $installDir 'Start tray icon.lnk'))
    $shortcut.TargetPath  = $powershell
    $shortcut.Arguments   = $trayArgs
    $shortcut.WindowStyle = 7
    $shortcut.Save()

    # ---- Start menu shortcut: opens the window, and starts the tray icon if automatic cleaning is on
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinSweep.lnk")
    $shortcut.TargetPath   = $powershell
    $shortcut.Arguments    = "$trayArgs -Open"
    $shortcut.IconLocation = "$(Join-Path $installDir 'WinSweep.ico'),0"
    $shortcut.WindowStyle  = 7
    $shortcut.Description  = 'WinSweep'
    $shortcut.Save()

    # Start the tray icon now when this copy runs without the non-admin launcher and UAC is off
    # (then every program runs with admin rights anyway).
    $uacOff = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System').EnableLUA -eq 0
    if (-not $FromLauncher -and $uacOff) { Start-Process $powershell -ArgumentList $trayArgs -WindowStyle Hidden }
    $trayNote = if (-not $schedule.Enabled) { "WinSweep doesn't start by itself. Open it from the Start menu when you need it." }
                elseif ($FromLauncher -or $uacOff) { 'The WinSweep icon next to the clock means it is active. Click it to open WinSweep.' }
                else { 'The WinSweep icon appears next to the clock at your next sign-in. To start it now, open WinSweep from the Start menu.' }

    $version = ((& (Join-Path $installDir 'WinSweep.ps1') -ShowSettings) -join "`n" | ConvertFrom-Json).Version
    $when = if ($schedule.Enabled) { "It cleans every $($schedule.Day) at $($schedule.Time)." } else { 'Automatic cleaning is off.' }
    $message = "WinSweep $version is installed.`n`n$when`n$trayNote"
    Write-Host $message
    if (-not $Quiet) { [Windows.MessageBox]::Show($message, 'WinSweep', 'OK', 'Information') | Out-Null }
} catch {
    $message = "WinSweep could not be installed:`n`n$($_.Exception.Message)"
    Write-Host $message
    if (-not $Quiet) { [Windows.MessageBox]::Show($message, 'WinSweep', 'OK', 'Error') | Out-Null }
    exit 1
}
