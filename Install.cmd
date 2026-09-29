@echo off
rem Double-click to install Temp Cleaner. Windows asks for admin permission once.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TempCleaner.ps1"
