@echo off
REM agentbox installer for Windows CMD — invokes install.ps1.
REM
REM Usage:
REM   curl -fsSL -o install.bat https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/install.bat
REM   install.bat
REM
REM Or directly:
REM   curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/install.bat | cmd

setlocal

where powershell >/dev/null 2>&1
if errorlevel 1 (
    echo install.bat: PowerShell not found. agentbox requires PowerShell on Windows.
    exit /b 1
)

echo install.bat: fetching install.ps1 and executing in PowerShell
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "iwr https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/install.ps1 -UseBasicParsing | iex"

if errorlevel 1 (
    echo install.bat: install.ps1 returned errorlevel %errorlevel%
    exit /b %errorlevel%
)

endlocal
