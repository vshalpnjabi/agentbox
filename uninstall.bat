@echo off
where powershell >/dev/null 2>&1 || (echo PowerShell required & exit /b 1)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "iwr https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/uninstall.ps1 -UseBasicParsing | iex"
