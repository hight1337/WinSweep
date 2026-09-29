@echo off
rem Double-click to remove Temp Cleaner. Windows asks for admin permission once.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-TempCleaner.ps1"
