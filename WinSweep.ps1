<#
.SYNOPSIS
    Removes temporary and junk files that Windows and apps leave behind.

.DESCRIPTION
    Each cleanup step can be turned on or off. The defaults are in the Settings block
    below; settings.json next to this script (written by WinSweepUI.ps1) overrides them.
    A file is removed only if it was neither created nor changed in the last $DaysOld days,
    so files that running apps and installers still use are left alone. Locked files are
    skipped and counted. Every real run writes a log to the logs folder next to this script.

.PARAMETER DryRun
    Show what would be deleted without deleting anything.

.PARAMETER SettingsFile
    Read settings from this file instead of settings.json. The settings window uses it
    to preview or clean with settings that are not saved yet.

.PARAMETER LiveLog
    Also write each log line and progress line to this file as it happens.
    The settings window reads it.

.PARAMETER ShowSettings
    Print the settings in effect and the step names as JSON, then exit.
#>
param(
    [switch]$DryRun,
    [string]$SettingsFile = (Join-Path $PSScriptRoot 'settings.json'),
    [string]$LiveLog,
    [switch]$ShowSettings
)

# ============================ Settings ============================
# Set each step to $true (run) or $false (skip).
$Steps = [ordered]@{
    UserTemp             = $true   # Temp folder of every user (installers, app leftovers)
    WindowsTemp          = $true   # C:\Windows\Temp (system and service leftovers)
    CrashDumps           = $true   # Crash memory dumps and Windows Error Reporting files
    UpdateDownloads      = $true   # Downloaded Windows Update files (re-downloaded if still needed)
    DeliveryOptimization = $true   # Update files cached to share with other PCs
    RecycleBin           = $false  # Items that have been in the Recycle Bin over $RecycleBinDays days
    ComponentCleanup     = $false  # DISM: old versions of updated Windows components (slow, 5-30 min)
}
$DaysOld        = 2      # Skip files created or changed in the last N days (1-365)
$RecycleBinDays = 30     # Recycle Bin: remove items deleted more than N days ago (1-3650)
$ListFiles      = $false # $true = write the path of every deleted file to the log
$KeepLogs       = 10     # Number of run logs to keep (1-1000)
# ==================================================================

# Step names used in the log and in the settings window.
$StepLabels = [ordered]@{
    UserTemp             = 'User temp folders'
    WindowsTemp          = 'Windows temp folder'
    CrashDumps           = 'Crash dumps and error reports'
    UpdateDownloads      = 'Windows Update downloads'
    DeliveryOptimization = 'Delivery Optimization cache'
    RecycleBin           = 'Old Recycle Bin items'
    ComponentCleanup     = 'Old Windows components (DISM)'
}

function Limit-Number([int]$value, [int]$min, [int]$max) { [math]::Max($min, [math]::Min($max, $value)) }

# A damaged settings file falls back to the defaults above.
try {
    if (Test-Path -LiteralPath $SettingsFile) {
        $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json
        foreach ($property in $saved.Steps.PSObject.Properties) {
            if ($Steps.Contains($property.Name)) { $Steps[$property.Name] = [bool]$property.Value }
        }
        if ($null -ne $saved.DaysOld)        { $DaysOld        = [int]$saved.DaysOld }
        if ($null -ne $saved.RecycleBinDays) { $RecycleBinDays = [int]$saved.RecycleBinDays }
        if ($null -ne $saved.ListFiles)      { $ListFiles      = [bool]$saved.ListFiles }
        if ($null -ne $saved.KeepLogs)       { $KeepLogs       = [int]$saved.KeepLogs }
    }
} catch { }

# Keep values in safe ranges, even if settings.json was edited by hand.
$DaysOld        = Limit-Number $DaysOld 1 365
$RecycleBinDays = Limit-Number $RecycleBinDays 1 3650
$KeepLogs       = Limit-Number $KeepLogs 1 1000

if ($ShowSettings) {
    [ordered]@{
        Steps = $Steps; Labels = $StepLabels; DaysOld = $DaysOld; RecycleBinDays = $RecycleBinDays
        ListFiles = $ListFiles; KeepLogs = $KeepLogs
    } | ConvertTo-Json
    return
}

$ErrorActionPreference = 'SilentlyContinue'
# Same number format on every PC, so the settings window can read the log.
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
$cutoff = (Get-Date).AddDays(-$DaysOld)
$logDir = Join-Path $PSScriptRoot 'logs'
$script:totalBytes  = 0
$script:totalFiles  = 0
$script:totalLocked = 0

# Log lines go to the console, the live log (settings window) and the run log. Both files
# stay open with AutoFlush, so a stopped or interrupted run still leaves a complete record.
function New-LogWriter([string]$path) {
    $stream = New-Object IO.FileStream($path, 'Append', 'Write', 'ReadWrite')
    $writer = New-Object IO.StreamWriter($stream, (New-Object Text.UTF8Encoding $false))
    $writer.AutoFlush = $true
    $writer
}
$liveWriter = if ($LiveLog) { New-LogWriter $LiveLog } else { $null }
$runWriter  = $null

function Write-Log([string]$message) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $message
    if ($liveWriter) { $liveWriter.WriteLine($line) }
    if ($runWriter)  { $runWriter.WriteLine($line) }
    Write-Output $line
}

# Progress for the settings window, as "@progress|step number|step count|step name|fraction|detail"
# lines in the live log. Fraction -1 means unknown. Sent at most every 250 ms unless -Force.
$progressClock      = [Diagnostics.Stopwatch]::StartNew()
$script:stepNumber  = 0
$script:stepLabel   = ''
$stepCount          = @($Steps.Keys | Where-Object { $Steps[$_] }).Count

function Send-Progress([string]$detail, [double]$fraction = -1, [switch]$Force) {
    if (-not $liveWriter) { return }
    if (-not $Force -and $progressClock.ElapsedMilliseconds -lt 250) { return }
    $progressClock.Restart()
    $liveWriter.WriteLine(('@progress|{0}|{1}|{2}|{3:0.####}|{4}' -f $script:stepNumber, $stepCount, $script:stepLabel, $fraction, $detail))
}

function Format-Size([double]$bytes) {
    if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) } else { '{0:N1} MB' -f ($bytes / 1MB) }
}

function Get-FreeBytes {
    [long](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'").FreeSpace
}

function Write-StepResult([string]$label, [double]$bytes, [int]$count, [int]$locked) {
    $line = '{0,-30} {1,10}  {2,7:N0} files' -f $label, (Format-Size $bytes), $count
    if ($locked) { $line += '  {0:N0} locked, skipped' -f $locked }
    Write-Log $line
    $script:totalBytes += $bytes; $script:totalFiles += $count; $script:totalLocked += $locked
}

# Lists everything under a folder without following junctions or symlinks, so nothing
# outside it is touched. Links are listed but not entered. Folders come parent-first.
# Uses .NET directly: about 10x faster than Get-ChildItem on folders with many files.
function Get-Tree([string]$path) {
    $tree = @{
        Files   = New-Object 'System.Collections.Generic.List[IO.FileInfo]'
        Folders = New-Object 'System.Collections.Generic.List[IO.DirectoryInfo]'
        Links   = New-Object 'System.Collections.Generic.List[IO.FileSystemInfo]'
    }
    $pending = New-Object 'System.Collections.Generic.Stack[IO.DirectoryInfo]'
    $pending.Push((New-Object IO.DirectoryInfo $path))
    $seen = 0
    while ($pending.Count) {
        try { $entries = $pending.Pop().GetFileSystemInfos() } catch { continue }
        foreach ($entry in $entries) {
            $seen++
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { $tree.Links.Add($entry) }
            elseif ($entry -is [IO.DirectoryInfo]) { $pending.Push($entry); $tree.Folders.Add($entry) }
            else { $tree.Files.Add($entry) }
        }
        if ($liveWriter -and $progressClock.ElapsedMilliseconds -ge 250) {
            Send-Progress ('Scanning {0}: {1:N0} items found' -f $path, $seen)
        }
    }
    $tree
}

function Remove-Entry([IO.FileSystemInfo]$entry) {
    try {
        if ($entry.Attributes -band [IO.FileAttributes]::ReadOnly) {
            $entry.Attributes = $entry.Attributes -bxor [IO.FileAttributes]::ReadOnly
        }
        $entry.Delete()
        $true
    } catch { $false }
}

# Deletes a whole folder. Links inside are removed as links; their targets are not touched.
function Remove-TreeSafe([string]$path) {
    $tree = Get-Tree $path
    foreach ($entry in $tree.Files) { Remove-Entry $entry | Out-Null }
    foreach ($entry in $tree.Links) { Remove-Entry $entry | Out-Null }
    $tree.Folders.Reverse()
    foreach ($entry in $tree.Folders) { Remove-Entry $entry | Out-Null }
    Remove-Entry (New-Object IO.DirectoryInfo $path) | Out-Null
}

function Test-Old([IO.FileSystemInfo]$entry) {
    $entry.LastWriteTime -lt $cutoff -and $entry.CreationTime -lt $cutoff
}

# Deletes old files under each path, then removes old folders left empty.
function Remove-OldFiles([string]$label, [string[]]$paths) {
    $bytes = 0; $count = 0; $locked = 0
    $verb = if ($DryRun) { 'Checking' } else { 'Deleting' }
    for ($p = 0; $p -lt $paths.Count; $p++) {
        $path = $paths[$p]
        if (-not [IO.Directory]::Exists($path)) { continue }

        Send-Progress "Scanning $path" -Force
        $tree = Get-Tree $path
        $files = @(foreach ($file in $tree.Files) {
            if ($file.LastWriteTime -lt $cutoff -and $file.CreationTime -lt $cutoff) { $file }
        })

        # Delete code is inline, not Remove-Entry: a function call per file is slow in PowerShell.
        for ($i = 0; $i -lt $files.Count; $i++) {
            $file = $files[$i]
            if ($liveWriter -and $progressClock.ElapsedMilliseconds -ge 250) {
                Send-Progress ('{0} {1:N0} of {2:N0} old files ({3}) in {4}' -f $verb, ($i + 1), $files.Count, (Format-Size $bytes), $path) `
                    (($p + $i / $files.Count) / $paths.Count)
            }
            if (-not $DryRun) {
                try {
                    if ($file.Attributes -band [IO.FileAttributes]::ReadOnly) { $file.Attributes = [IO.FileAttributes]::Normal }
                    $file.Delete()
                } catch { $locked++; continue }
            }
            $bytes += $file.Length; $count++
            if ($ListFiles) { Write-Log "      $($file.FullName)" }
        }

        # Deepest folders first. Delete() fails on folders that are not empty, so only
        # empty ones go. The top folder itself stays.
        if (-not $DryRun) {
            $tree.Folders.Reverse()
            foreach ($folder in $tree.Folders) {
                if (Test-Old $folder) { Remove-Entry $folder | Out-Null }
            }
        }
    }
    Write-StepResult $label $bytes $count $locked
}

# Each Recycle Bin item is a $I file (original size at byte 8, deletion date at byte 16)
# plus a $R file or folder with the data, in one folder per user under $Recycle.Bin.
function Clear-OldRecycleBin([string]$label) {
    $binCutoff = (Get-Date).AddDays(-$RecycleBinDays)
    $bytes = 0; $count = 0; $locked = 0
    foreach ($drive in Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3') {
        $bin = New-Object IO.DirectoryInfo "$($drive.DeviceID)\`$Recycle.Bin"
        if (-not $bin.Exists) { continue }
        try { $userBins = $bin.GetDirectories() } catch { continue }
        foreach ($userBin in $userBins) {
            try { $infoFiles = $userBin.GetFiles('$I*') } catch { continue }
            foreach ($info in $infoFiles) {
                Send-Progress ('Checking the Recycle Bin on {0}: {1:N0} old items so far' -f $drive.DeviceID, $count)
                try {
                    $raw     = [IO.File]::ReadAllBytes($info.FullName)
                    $size    = [BitConverter]::ToInt64($raw, 8)
                    $deleted = [DateTime]::FromFileTime([BitConverter]::ToInt64($raw, 16))
                } catch { continue }
                if ($deleted -ge $binCutoff) { continue }

                $dataPath = Join-Path $userBin.FullName ('$R' + $info.Name.Substring(2))
                if (-not $DryRun) {
                    $data = Get-Item -LiteralPath $dataPath -Force
                    if ($data) {
                        if ($data.PSIsContainer -and -not ($data.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                            Remove-TreeSafe $dataPath
                        } else {
                            Remove-Entry $data | Out-Null
                        }
                        if (Test-Path -LiteralPath $dataPath) { $locked++; continue }
                    }
                    Remove-Entry $info | Out-Null
                }
                $bytes += $size; $count++
                if ($ListFiles) { Write-Log "      $dataPath (deleted $deleted)" }
            }
        }
    }
    Write-StepResult $label $bytes $count $locked
}

# Runs a step whose size is only known from the free space before and after.
function Invoke-FreeSpaceStep([string]$label, [string]$progressText, [scriptblock]$action) {
    Send-Progress $progressText -Force
    $before = Get-FreeBytes
    $message = & $action
    $freed = [math]::Max(0, (Get-FreeBytes) - $before)
    Write-Log ('{0,-30} {1,10}  {2}' -f $label, (Format-Size $freed), $message)
    $script:totalBytes += $freed
}

# ------------------------------ Run ------------------------------
if (-not $DryRun) {
    # Only one cleanup at a time: the weekly task and "Clean now" could overlap.
    $mutex = New-Object Threading.Mutex($false, 'Global\WinSweep')
    try { $owned = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) {
        Write-Log 'Another cleanup is already running. Try again when it has finished.'
        exit 1
    }

    # Refuse a logs folder that is a link, so the log never lands somewhere else.
    $logInfo = New-Object IO.DirectoryInfo $logDir
    if (-not ($logInfo.Exists -and ($logInfo.Attributes -band [IO.FileAttributes]::ReparsePoint))) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        $runWriter = New-LogWriter (Join-Path $logDir ('run-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date)))
        Get-ChildItem -LiteralPath $logDir -Filter 'run-*.log' | Sort-Object Name -Descending |
            Select-Object -Skip $KeepLogs | Remove-Item -Force
    }
}

$freeBefore = Get-FreeBytes
Write-Log $(if ($DryRun) { 'Preview started. Nothing is deleted.' } else { 'Cleanup started.' })
Write-Log ('Keeping files created or changed in the last {0} days. Free space on {1} {2}' -f
    $DaysOld, $env:SystemDrive, (Format-Size $freeBefore))

$userDirs = @(Get-ChildItem -LiteralPath "$env:SystemDrive\Users" -Directory | Select-Object -ExpandProperty FullName)

foreach ($step in $Steps.Keys) {
    $label = $StepLabels[$step]
    if (-not $Steps[$step]) { Write-Log ('{0,-30} off' -f $label); continue }

    $script:stepNumber++
    $script:stepLabel = $label
    Send-Progress 'Starting' -Force

    switch ($step) {
        'UserTemp'    { Remove-OldFiles $label ($userDirs | ForEach-Object { "$_\AppData\Local\Temp" }) }
        'WindowsTemp' { Remove-OldFiles $label @("$env:SystemRoot\Temp") }
        'CrashDumps'  {
            Remove-OldFiles $label (@(
                "$env:SystemRoot\Minidump"
                "$env:SystemRoot\LiveKernelReports"
                "$env:ProgramData\Microsoft\Windows\WER\ReportArchive"
                "$env:ProgramData\Microsoft\Windows\WER\ReportQueue"
            ) + ($userDirs | ForEach-Object { "$_\AppData\Local\CrashDumps" }))
        }
        'UpdateDownloads' {
            # Files of an update that waits for a restart are still needed to finish installing it.
            if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
                Write-Log ('{0,-30} skipped: an update is waiting for a restart' -f $label)
            } else {
                Remove-OldFiles $label @("$env:SystemRoot\SoftwareDistribution\Download")
            }
        }
        'DeliveryOptimization' {
            if ($DryRun) { Write-Log ('{0,-30} will be cleared; size is known only after cleaning' -f $label) }
            else { Invoke-FreeSpaceStep $label 'Clearing the cache' { Delete-DeliveryOptimizationCache -Force | Out-Null; 'cleared' } }
        }
        'RecycleBin' { Clear-OldRecycleBin $label }
        'ComponentCleanup' {
            if ($DryRun) { Write-Log ('{0,-30} will run DISM; size is known only after cleaning' -f $label) }
            else {
                Invoke-FreeSpaceStep $label 'Running DISM. This can take 5-30 minutes.' {
                    & "$env:SystemRoot\System32\Dism.exe" /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null
                    if ($LASTEXITCODE -eq 0) { 'done' } else { "DISM failed with exit code $LASTEXITCODE" }
                }
            }
        }
    }
}

$freeAfter = Get-FreeBytes
if ($DryRun) {
    Write-Log ('Done. Would free {0} in {1:N0} files.' -f (Format-Size $script:totalBytes), $script:totalFiles)
} else {
    $done = 'Done. Freed {0}. Deleted {1:N0} files.' -f (Format-Size $script:totalBytes), $script:totalFiles
    if ($script:totalLocked) { $done += ' Skipped {0:N0} files that are in use.' -f $script:totalLocked }
    Write-Log $done
}
Write-Log ('Free space on {0} {1} before, {2} after.' -f $env:SystemDrive, (Format-Size $freeBefore), (Format-Size $freeAfter))

if ($runWriter)  { $runWriter.Dispose() }
if ($liveWriter) { $liveWriter.Dispose() }
if ($mutex)      { $mutex.ReleaseMutex() }
