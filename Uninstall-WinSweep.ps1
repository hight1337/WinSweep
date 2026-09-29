<#
.SYNOPSIS
    Removes WinSweep: the tray icon and its startup entry, the scheduled task, the Start menu
    shortcut, C:\ProgramData\WinSweep (scripts, settings and logs) and older leftovers.

.PARAMETER Quiet
    Do not show the message at the end.
#>
param([switch]$Quiet)

# Restart with admin rights if needed.
$identity = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    if ($Quiet) { $arguments += ' -Quiet' }
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments } catch { }
    exit
}

$installDir = Join-Path $env:ProgramData 'WinSweep'

# Tray icons (of every user) and an open settings window
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*WinSweepTray.ps1*' -or $_.CommandLine -like '*WinSweepUI.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Remove-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'WinSweep' -ErrorAction SilentlyContinue

# Scheduled tasks and their folder, including those of older versions
foreach ($task in @(@('\WinSweep\', 'Cleanup'), @('\WinSweep\', 'Settings'), @('\WinSweep\', 'Preview'), @('\', 'WinSweep'))) {
    Unregister-ScheduledTask -TaskPath $task[0] -TaskName $task[1] -Confirm:$false -ErrorAction SilentlyContinue
}
try {
    $scheduler = New-Object -ComObject Schedule.Service
    $scheduler.Connect()
    $scheduler.GetFolder('\').DeleteFolder('WinSweep', 0)
} catch { }

Remove-Item -LiteralPath "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinSweep.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:APPDATA 'WinSweep') -Recurse -Force -ErrorAction SilentlyContinue   # 1.1 test builds
Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue

$message = if (Test-Path -LiteralPath $installDir) {
    "WinSweep was removed, but $installDir could not be deleted completely. Restart the PC and delete it by hand."
} else { 'WinSweep was removed.' }
Write-Host $message
if (-not $Quiet) {
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show($message, 'WinSweep', 'OK', 'Information') | Out-Null
}
