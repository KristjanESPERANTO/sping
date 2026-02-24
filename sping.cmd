@echo off
:: sping - Smart Ping Tool
:: Wrapper to launch sping.ps1 via PowerShell

:: Determine the directory of this script
set "SPING_DIR=%~dp0"

:: Pass all arguments through to the PowerShell script
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SPING_DIR%sping.ps1" %*
