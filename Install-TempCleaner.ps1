<#
.SYNOPSIS
    Installs TempCleaner and schedules it to run once a week.

.DESCRIPTION
    Copies CleanTemp.ps1 and TempCleanerUI.ps1 to C:\ProgramData\TempCleaner,
    registers the "TempCleaner" scheduled task and adds a "Temp Cleaner" Start menu
    shortcut that opens the settings window. The task runs as SYSTEM every week on
    -Day at -At. If the PC is off at that time, the task runs as soon as the PC is on again.
    Settings saved in the window (settings.json) are kept when you install again.
    To remove everything, run Uninstall.cmd.

.PARAMETER Quiet
    Do not show the "Installed" message at the end.
#>
param(
    [ValidateSet('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')]
    [string]$Day = 'Sunday',
    [string]$At = '12:00',
    [switch]$Quiet
)

Add-Type -AssemblyName PresentationFramework

# Restart with admin rights if needed.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Day $Day -At `"$At`""
    if ($Quiet) { $arguments += ' -Quiet' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments -ErrorAction Stop }
    catch {
        [Windows.MessageBox]::Show('Temp Cleaner was not installed, because admin permission was not given.',
            'Temp Cleaner', 'OK', 'Information') | Out-Null
    }
    exit
}

$ErrorActionPreference = 'Stop'
try {
    $installDir = 'C:\ProgramData\TempCleaner'
    $scriptPath = Join-Path $installDir 'CleanTemp.ps1'
    $uiPath     = Join-Path $installDir 'TempCleanerUI.ps1'

    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'CleanTemp.ps1') -Destination $scriptPath -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TempCleanerUI.ps1') -Destination $uiPath -Force

    # SYSTEM runs the cleaner from this folder, so only admins and SYSTEM may change files in it.
    # By default any user can add files under C:\ProgramData. SIDs work on every Windows language:
    # S-1-5-18 SYSTEM, S-1-5-32-544 Administrators, S-1-5-32-545 Users.
    & icacls.exe $installDir /setowner '*S-1-5-32-544' /T /C /Q | Out-Null
    & icacls.exe $installDir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' '*S-1-5-32-545:(OI)(CI)RX' /Q | Out-Null
    & icacls.exe "$installDir\*" /reset /T /C /Q | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Could not set permissions on $installDir." }

    $time = [datetime]::ParseExact($At, 'H:mm', [Globalization.CultureInfo]::InvariantCulture)
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                     -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`""
    $trigger   = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $Day -At $time
    # Local time without a time zone, so the task keeps its clock time after daylight saving changes.
    $trigger.StartBoundary = $time.ToString('yyyy-MM-dd\THH:mm:ss')
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
                     -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName 'TempCleaner' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force `
        -Description 'Weekly cleanup of temp and junk files. Settings: Start menu > Temp Cleaner.' | Out-Null

    $shortcutPath = "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Temp Cleaner.lnk"
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $shortcut.TargetPath   = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments    = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$uiPath`""
    $shortcut.IconLocation = "$env:SystemRoot\System32\cleanmgr.exe,0"
    $shortcut.WindowStyle  = 7
    $shortcut.Description  = 'Temp Cleaner settings'
    $shortcut.Save()

    $message = "Temp Cleaner is installed.`n`nIt cleans every $Day at $At.`nTo change settings or clean now, open Start menu > Temp Cleaner."
    Write-Host $message
    if (-not $Quiet) { [Windows.MessageBox]::Show($message, 'Temp Cleaner', 'OK', 'Information') | Out-Null }
} catch {
    $message = "Temp Cleaner could not be installed:`n`n$($_.Exception.Message)"
    Write-Host $message
    if (-not $Quiet) { [Windows.MessageBox]::Show($message, 'Temp Cleaner', 'OK', 'Error') | Out-Null }
    exit 1
}
