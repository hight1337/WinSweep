# WinSweep

WinSweep deletes temp and junk files on Windows. It runs automatically on a schedule you choose, and
you can also start a cleanup yourself at any time. It's a few PowerShell scripts and a small settings
window. It doesn't connect to the internet, and the only things it adds to your system are a scheduled
task and a Start menu shortcut.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE)

![WinSweep settings window](docs/screenshot.png)

## Install

1. [Download the ZIP](https://github.com/hight1337/WinSweep/archive/refs/heads/main.zip) (or use **Code > Download ZIP** on this page).
2. Unzip it.
3. Double-click `Install.cmd` and allow the admin prompt.

Windows will probably show "Windows protected your PC", because the scripts aren't signed. Click
**More info**, then **Run anyway**. If you want to check the code first, every file is plain text and
opens in Notepad.

You need Windows 10 or 11. PowerShell 5.1 comes with Windows, so there's nothing else to install.

## Using it

After you install it, WinSweep runs automatically every Sunday at 12:00. You can pick a different day
and time, or turn automatic runs off. If the PC is off at the scheduled time, it runs the next time you
turn it on.

To change anything, open **WinSweep** from the Start menu. There you can choose what to clean, change
the day and time, click **Preview** to see what would be deleted (nothing is deleted), or **Clean now**.
Each cleanup writes a log to `C:\ProgramData\WinSweep\logs`, and the last 10 logs are kept.

## What gets deleted

A file is deleted only if it was created and last changed more than 2 days ago. Files that are in use
are skipped. You can change the 2 days in the settings window.

On by default:

- `C:\Users\<name>\AppData\Local\Temp`, for every user
- `C:\Windows\Temp`
- Crash dumps and error reports: `C:\Windows\Minidump`, `C:\Windows\LiveKernelReports`,
  `C:\ProgramData\Microsoft\Windows\WER` and `AppData\Local\CrashDumps` for every user
- Windows Update downloads in `C:\Windows\SoftwareDistribution\Download`. This is skipped while an
  update is waiting for a restart.
- The Delivery Optimization cache, cleared with Windows' own `Delete-DeliveryOptimizationCache`

Off by default:

- Recycle Bin items deleted more than 30 days ago
- `DISM /Online /Cleanup-Image /StartComponentCleanup`, which removes old versions of Windows
  components. It takes 5 to 30 minutes.

## What it doesn't touch

Your own files (Documents, Downloads, Desktop and so on), browser caches, Prefetch, event logs, the
registry and Windows settings. It doesn't follow junctions or symlinks either, so it can't reach
anything outside the folders listed above.

Browser caches and Prefetch are left alone on purpose. Clearing them mostly makes things slower for a
while, and they fill up again anyway.

## How it works

`Install.cmd` copies the scripts to `C:\ProgramData\WinSweep` and sets that folder so only
administrators can change them. That matters because the scheduled task runs the cleaner as SYSTEM.
Then it registers a scheduled task named `WinSweep` and adds the Start menu shortcut.

`WinSweep.ps1` does the cleaning. It reads folders with the .NET file APIs instead of `Get-ChildItem`,
which is about 10 times faster on large folders. On my PC it scans the Windows Update folder (about
200,000 files) in around a second. Only one cleanup can run at a time.

To try the cleaner without installing it or deleting anything, run this in the unzipped folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\WinSweep.ps1 -DryRun
```

## Uninstall

Double-click `Uninstall.cmd`. It removes the scheduled task, the Start menu shortcut and
`C:\ProgramData\WinSweep`, including your settings and logs.

## FAQ

**Can I get deleted files back?**
No. Files are deleted, not moved to the Recycle Bin. Run Preview first if you're not sure.

**Why does it need admin rights?**
Cleaning `C:\Windows\Temp` and the Windows Update folder needs them, and so does creating the
scheduled task.

**Does it send any data anywhere?**
No. There's no network code in the scripts.

**Does it work on Windows in other languages?**
Yes.

## Files

| File | What it does |
|---|---|
| `WinSweep.ps1` | The cleaner. The scheduled task and the settings window both run it |
| `WinSweepUI.ps1` | The settings window |
| `Install-WinSweep.ps1` | Copies the scripts, sets folder permissions, creates the task and the shortcut |
| `Uninstall-WinSweep.ps1` | Removes everything the installer added |
| `Install.cmd`, `Uninstall.cmd` | Double-click these instead of running the scripts directly |

## Contributing

Bug reports and pull requests are welcome in [Issues](../../issues). If WinSweep is useful to you, a
star helps other people find it.

## License

[MIT](LICENSE)
