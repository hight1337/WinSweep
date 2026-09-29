<#
.SYNOPSIS
    Removes WinSweep: the scheduled task, the Start menu shortcut and
    C:\ProgramData\WinSweep (scripts, settings and logs).

.PARAMETER Quiet
    Do not show the "Removed" message at the end.
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

Unregister-ScheduledTask -TaskName 'WinSweep' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\WinSweep.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'C:\ProgramData\WinSweep' -Recurse -Force -ErrorAction SilentlyContinue

if (-not $Quiet) {
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show('WinSweep was removed.', 'WinSweep', 'OK', 'Information') | Out-Null
}
