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

# Version shown in the settings window and in every log. Raise it for each change you share.
$Version = '1.1.0'

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
# When the tray icon starts automatic cleanups. The cleaner itself does not use this.
$Schedule = [ordered]@{ Enabled = $true; Day = 'Sunday'; Time = '12:00' }
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

# Values from settings.json, which may have been edited by hand: a number is kept in its range,
# and a true/false also accepts the text "true" or "false".
function Get-Number($value, [int]$default, [int]$min, [int]$max) {
    $number = 0L
    if (-not [long]::TryParse("$value", [ref]$number)) { return $default }
    [int][math]::Max([long]$min, [math]::Min([long]$max, $number))
}
function Get-Switch($value, [bool]$default) {
    if ($value -is [bool]) { return $value }
    if ("$value" -in 'true', 'false') { return "$value" -eq 'true' }
    $default
}

# A missing or damaged settings file falls back to the defaults above.
$saved = $null
if (Test-Path -LiteralPath $SettingsFile) {
    try { $saved = Get-Content -LiteralPath $SettingsFile -Raw | ConvertFrom-Json } catch { }
}
if ($saved) {
    foreach ($property in $saved.Steps.PSObject.Properties) {
        if ($Steps.Contains($property.Name)) { $Steps[$property.Name] = Get-Switch $property.Value $Steps[$property.Name] }
    }
    $DaysOld        = Get-Number $saved.DaysOld $DaysOld 1 365
    $RecycleBinDays = Get-Number $saved.RecycleBinDays $RecycleBinDays 1 3650
    $ListFiles      = Get-Switch $saved.ListFiles $ListFiles
    $KeepLogs       = Get-Number $saved.KeepLogs $KeepLogs 1 1000
    if ($saved.Schedule) {
        $Schedule.Enabled = Get-Switch $saved.Schedule.Enabled $Schedule.Enabled
        if ("$($saved.Schedule.Day)" -in [Enum]::GetNames([DayOfWeek])) { $Schedule.Day = "$($saved.Schedule.Day)" }
        $time = [datetime]::MinValue
        if ([datetime]::TryParseExact("$($saved.Schedule.Time)", 'H:mm', [Globalization.CultureInfo]::InvariantCulture, 'None', [ref]$time)) {
            $Schedule.Time = $time.ToString('HH:mm')
        }
    }
}

if ($ShowSettings) {
    [ordered]@{
        Version = $Version
        Steps = $Steps; Labels = $StepLabels; DaysOld = $DaysOld; RecycleBinDays = $RecycleBinDays
        ListFiles = $ListFiles; KeepLogs = $KeepLogs; Schedule = $Schedule
    } | ConvertTo-Json
    return
}

# Deleting uses WinSweep.Native.dll, which the installer builds into the program folder.
# From the source folder the helper is built on the fly (not as SYSTEM: Windows' temp folder,
# where it would be built, can be written by any user).
if (-not $DryRun) {
    $nativeDll = Join-Path $PSScriptRoot 'WinSweep.Native.dll'
    if (Test-Path -LiteralPath $nativeDll) {
        Add-Type -Path $nativeDll
    } elseif (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        Add-Type -TypeDefinition (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'WinSweepNative.cs') -Raw)
    } else {
        Write-Output 'WinSweep.Native.dll is missing. Run Install.cmd again.'
        exit 1
    }
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

# Deletes a whole folder (a Recycle Bin item) inside root. Links inside are removed as links;
# their targets are not touched.
function Remove-Tree([string]$path, [string]$root) {
    $tree = Get-Tree $path
    foreach ($entry in $tree.Files) { [void][WinSweep.SafeDelete]::Delete($entry.FullName, $root, $false) }
    foreach ($entry in $tree.Links) { [void][WinSweep.SafeDelete]::Delete($entry.FullName, $root, $entry -is [IO.DirectoryInfo]) }
    $tree.Folders.Reverse()
    foreach ($entry in $tree.Folders) { [void][WinSweep.SafeDelete]::Delete($entry.FullName, $root, $true) }
    [WinSweep.SafeDelete]::Delete($path, $root, $true)
}

function Test-Old([IO.FileSystemInfo]$entry) {
    $entry.LastWriteTime -lt $cutoff -and $entry.CreationTime -lt $cutoff
}

# Deletes old files under each path, then removes old folders left empty. Every item is
# deleted through [WinSweep.SafeDelete], which checks that it is really inside the path.
function Remove-OldFiles([string]$label, [string[]]$paths) {
    $bytes = 0; $count = 0; $locked = 0
    $verb = if ($DryRun) { 'Checking' } else { 'Deleting' }
    for ($p = 0; $p -lt $paths.Count; $p++) {
        $path = $paths[$p]
        if (-not [IO.Directory]::Exists($path)) { continue }
        if (-not $DryRun) {
            # A path that is (or runs through) a link could lead anywhere: skip it.
            $root = [WinSweep.SafeDelete]::CheckRoot($path)
            if (-not $root) { Write-Log "      skipped $path (it is a link to another folder)"; continue }
        }

        Send-Progress "Scanning $path" -Force
        $tree = Get-Tree $path
        $files = @(foreach ($file in $tree.Files) {
            if ($file.LastWriteTime -lt $cutoff -and $file.CreationTime -lt $cutoff) { $file }
        })

        for ($i = 0; $i -lt $files.Count; $i++) {
            $file = $files[$i]
            if ($liveWriter -and $progressClock.ElapsedMilliseconds -ge 250) {
                Send-Progress ('{0} {1:N0} of {2:N0} old files ({3}) in {4}' -f $verb, ($i + 1), $files.Count, (Format-Size $bytes), $path) `
                    (($p + $i / $files.Count) / $paths.Count)
            }
            if (-not $DryRun) {
                $result = [WinSweep.SafeDelete]::Delete($file.FullName, $root, $false)
                if ($result -eq [WinSweep.SafeDelete]::InUse) { $locked++; continue }
                if ($result -ne [WinSweep.SafeDelete]::Deleted) { continue }   # gone already, or moved outside
            }
            $bytes += $file.Length; $count++
            if ($ListFiles) { Write-Log "      $($file.FullName)" }
        }

        # Deepest folders first. Folders that are not empty stay. The top folder itself stays.
        if (-not $DryRun) {
            $tree.Folders.Reverse()
            foreach ($folder in $tree.Folders) {
                if (Test-Old $folder) { [void][WinSweep.SafeDelete]::Delete($folder.FullName, $root, $true) }
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
            $root = if ($DryRun) { $userBin.FullName } else { [WinSweep.SafeDelete]::CheckRoot($userBin.FullName) }
            if (-not $root) { continue }
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
                        $isFolder = $data.PSIsContainer
                        $isLink   = [bool]($data.Attributes -band [IO.FileAttributes]::ReparsePoint)
                        $result = if ($isFolder -and -not $isLink) { Remove-Tree $dataPath $root }
                                  else { [WinSweep.SafeDelete]::Delete($dataPath, $root, $isFolder) }
                        if ($result -ne [WinSweep.SafeDelete]::Deleted) { $locked++; continue }
                    }
                    [void][WinSweep.SafeDelete]::Delete($info.FullName, $root, $false)
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
    $freed = [math]::Max([long]0, (Get-FreeBytes) - $before)
    Write-Log ('{0,-30} {1,10}  {2}' -f $label, (Format-Size $freed), $message)
    $script:totalBytes += $freed
}

# status.json tells the tray icon whether a cleanup is running and when the last one ended.
# Only real cleanups write it. It is replaced in one step, so a reader never sees half a file.
$statusFile = Join-Path $PSScriptRoot 'status.json'

function Read-Status {
    try { Get-Content -LiteralPath $statusFile -Raw -ErrorAction Stop | ConvertFrom-Json } catch { $null }
}

function Write-Status($status) {
    $temp = "$statusFile.tmp"
    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            $status | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temp -Encoding UTF8 -ErrorAction Stop
            if ([IO.File]::Exists($statusFile)) { [IO.File]::Replace($temp, $statusFile, $null) }
            else { [IO.File]::Move($temp, $statusFile) }
            return
        } catch {
            Start-Sleep -Milliseconds 200   # the tray icon may be reading it
        }
    }
    Write-Log "Could not update $statusFile."
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

    $previous = Read-Status
    $status = [ordered]@{
        Version    = $Version
        Running    = $true
        RunPid     = $PID
        RunStarted = (Get-Date).ToString('o')
        LastRun    = $previous.LastRun
        Totals     = if ($previous.Totals) { $previous.Totals }
                     else { [ordered]@{ FreedBytes = 0; Runs = 0; Since = (Get-Date).ToString('o') } }
    }
    Write-Status $status
}

$freeBefore = Get-FreeBytes
Write-Log $(if ($DryRun) { "WinSweep $Version. Preview started. Nothing is deleted." } else { "WinSweep $Version. Cleanup started." })
Write-Log ('Keeping files created or changed in the last {0} days. Free space on {1} {2}' -f
    $DaysOld, $env:SystemDrive, (Format-Size $freeBefore))

$userDirs = @(Get-ChildItem -LiteralPath "$env:SystemDrive\Users" -Directory | Select-Object -ExpandProperty FullName)

$failure = $null
try {
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
} catch {
    $failure = $_.Exception.Message
    Write-Log "Stopped because of an error: $failure"
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

if ($status) {
    $status.Running = $false
    $status.LastRun = [ordered]@{
        Finished   = (Get-Date).ToString('o')
        Result     = if ($failure) { 'failed' } else { 'ok' }
        Message    = $failure
        FreedBytes = [long]$script:totalBytes
        Files      = $script:totalFiles
        Locked     = $script:totalLocked
    }
    $status.Totals = [ordered]@{
        FreedBytes = [long]$status.Totals.FreedBytes + [long]$script:totalBytes
        Runs       = [int]$status.Totals.Runs + 1
        Since      = $status.Totals.Since
    }
    Write-Status $status
}

if ($runWriter)  { $runWriter.Dispose() }
if ($liveWriter) { $liveWriter.Dispose() }
if ($mutex)      { $mutex.ReleaseMutex() }
