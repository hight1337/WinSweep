@echo off
rem Double-click to remove WinSweep. Windows asks for admin permission once.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-WinSweep.ps1"
