# Temp Cleaner

**A small, open-source Windows tool that deletes temp and junk files once a week, in the background.**
No ads, no internet connection, no bundled software. Just readable PowerShell scripts you can check yourself.

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![Windows 10 | 11](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6)
![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-5391FE)
![No network access](https://img.shields.io/badge/network-none-success)

![Temp Cleaner settings window](docs/screenshot.png)

## Contents

- [Why you can trust it](#why-you-can-trust-it)
- [Install](#install)
- [Use](#use)
- [What it cleans](#what-it-cleans)
- [What it never touches](#what-it-never-touches)
- [How it works](#how-it-works)
- [Uninstall](#uninstall)
- [FAQ](#faq)
- [Files in this repository](#files-in-this-repository)
- [License](#license)

## Why you can trust it

| | |
|---|---|
| **Open source, nothing hidden** | About 1,000 lines of plain PowerShell. No `.exe`, no compiled code. Open any file in Notepad and read what it does. |
| **No internet access** | The scripts never connect to the internet. No telemetry, no updates from a server, no data leaves your PC. |
| **Only known junk folders** | It deletes only in the folders listed under [What it cleans](#what-it-cleans). The exact paths are in `CleanTemp.ps1`. |
| **Recent files are safe** | A file is deleted only if it was neither created nor changed in the last 2 days (you can raise this). Files that apps are using right now are skipped. |
| **Try before you trust** | **Preview** shows exactly what would be deleted, and deletes nothing. |
| **Everything is logged** | Each cleanup writes a log of what it removed to `C:\ProgramData\TempCleaner\logs`. |
| **Easy to remove** | `Uninstall.cmd` removes the task, the shortcut and the program folder. Nothing is left behind. |

## Install

1. [**Download the ZIP**](https://github.com/hight1337/TempCleaner/archive/refs/heads/main.zip), or click the green **Code** button above, then **Download ZIP**.
2. Unzip it anywhere.
3. Open the unzipped folder and double-click **`Install.cmd`**. Click **Yes** when Windows asks for admin permission.

> **"Windows protected your PC"?** Click **More info**, then **Run anyway**.
> Windows shows this for every downloaded script that is not signed with a paid certificate. It is not a virus warning.

Requirements: Windows 10 or 11. PowerShell 5.1 is already part of Windows, so there is nothing else to install.

## Use

Open **Start menu > Temp Cleaner**. Windows asks for admin permission each time, because cleaning system folders needs it.

| Button | What it does |
|---|---|
| **Preview** | Shows what would be deleted and how much space it would free. **Nothing is deleted.** |
| **Clean now** | Deletes the selected junk files now, with a progress bar and a live log. |
| **Stop** | Stops a running cleanup. |
| **Save** | Saves your choices and the schedule. |
| **Open logs folder** | Opens the folder with the cleanup logs. |

By default it cleans **every Sunday at 12:00**. If the PC is off at that time, it cleans the next time the PC is on.

## What it cleans

On by default:

| Item | Folder | What it is |
|---|---|---|
| User temp folders | `C:\Users\<name>\AppData\Local\Temp` | Installer leftovers and app scratch files |
| Windows temp folder | `C:\Windows\Temp` | Leftovers from Windows and services |
| Crash dumps and error reports | `C:\Windows\Minidump`, `C:\Windows\LiveKernelReports`, `C:\ProgramData\Microsoft\Windows\WER`, `C:\Users\<name>\AppData\Local\CrashDumps` | Saved when an app or Windows crashes |
| Windows Update downloads | `C:\Windows\SoftwareDistribution\Download` | Updates that are already installed. **Skipped while an update waits for a restart.** |
| Delivery Optimization cache | Managed by Windows | Update files kept to share with other PCs. Cleared with the built-in `Delete-DeliveryOptimizationCache` command. |

Off by default (turn on in the window if you want):

| Item | What it is |
|---|---|
| Old Recycle Bin items | Only items deleted more than 30 days ago (you can change the number) |
| Old Windows components | Runs the built-in `DISM /Online /Cleanup-Image /StartComponentCleanup`. Slow: 5-30 minutes |

## What it never touches

- Your documents, downloads, desktop, pictures and any other personal files
- Files created or changed in the last 2 days, and files that are in use
- Anything outside the folders listed above. It never follows links (junctions or symlinks) out of those folders.
- Browser caches, Prefetch and event logs. Clearing those makes Windows or apps slower, or removes information you need when troubleshooting.
- Windows settings and the registry

## How it works

```
Install.cmd
  └─ copies the scripts to C:\ProgramData\TempCleaner (only admins can change them there)
  └─ adds the weekly task "TempCleaner" in Task Scheduler (runs as SYSTEM)
  └─ adds the "Temp Cleaner" Start menu shortcut

Every week, or when you click Clean now
  └─ CleanTemp.ps1 lists each folder, keeps recent and in-use files,
     deletes the rest and writes a log
```

Details:

- **Fast.** It uses Windows' file functions directly, so it scans about 200,000 files in about 1 second.
- **One run at a time.** The weekly run and **Clean now** can't overlap.
- **Settings** are saved in `C:\ProgramData\TempCleaner\settings.json`.
- **Logs:** the last 10 are kept in `C:\ProgramData\TempCleaner\logs`.

## Uninstall

Double-click **`Uninstall.cmd`** and click **Yes**. This removes the weekly task, the Start menu shortcut and `C:\ProgramData\TempCleaner`.

## FAQ

**Can I get deleted files back?**
No. Files are deleted directly, not moved to the Recycle Bin. That is why **Preview** exists and why recent files are always kept.

**Why does it need admin rights?**
`C:\Windows\Temp`, the Windows Update folder and the scheduled task all need admin rights. The window asks each time you open it, and the installer asks once.

**Will it slow my PC down?**
No. It runs once a week for a few seconds in the background. Deleting temp files does not affect how fast apps start.

**Does it work on other languages of Windows?**
Yes. It uses language-independent system names everywhere.

**Can I change the schedule or what gets cleaned?**
Yes. Open **Start menu > Temp Cleaner**, change the options and click **Save**.

## Files in this repository

| File | Purpose |
|---|---|
| `CleanTemp.ps1` | The cleaner. Run by the weekly task and by the window |
| `TempCleanerUI.ps1` | The settings window |
| `Install-TempCleaner.ps1` | Installer: copies the scripts, locks the program folder to admins, registers the task, adds the shortcut |
| `Uninstall-TempCleaner.ps1` | Removes everything the installer added |
| `Install.cmd`, `Uninstall.cmd` | Double-click wrappers for the two scripts |

Try the cleaner from this folder without deleting anything:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\CleanTemp.ps1 -DryRun
```

Found a bug or have an idea? [Open an issue](../../issues).

## License

[MIT](LICENSE). Free to use, change and share. No warranty: use at your own risk, and try **Preview** first.
