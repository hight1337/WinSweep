<#
.SYNOPSIS
    Removes TempCleaner: the scheduled task, the Start menu shortcut and
    C:\ProgramData\TempCleaner (scripts, settings and logs).

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

Unregister-ScheduledTask -TaskName 'TempCleaner' -Confirm:$false -ErrorAction SilentlyContinue
Remove-Item -LiteralPath "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Temp Cleaner.lnk" -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath 'C:\ProgramData\TempCleaner' -Recurse -Force -ErrorAction SilentlyContinue

if (-not $Quiet) {
    Add-Type -AssemblyName PresentationFramework
    [Windows.MessageBox]::Show('Temp Cleaner was removed.', 'Temp Cleaner', 'OK', 'Information') | Out-Null
}
