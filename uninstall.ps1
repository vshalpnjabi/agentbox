# agentbox uninstaller for Windows (PowerShell) — proxies through WSL.
#
# Usage:
#   iwr https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/uninstall.ps1 | iex

param([switch]$All, [switch]$Yes)

function Log($msg) { Write-Host "uninstall.ps1: $msg" -ForegroundColor Cyan }
function Err($msg) { Write-Host "uninstall.ps1: $msg" -ForegroundColor Red; exit 1 }

try { $null = wsl --status 2>$null } catch { Err "WSL not available; agentbox runs inside WSL so this Windows-side uninstaller has nothing to do." }

$flag = ""
if ($All) { $flag += " --all" }
if ($Yes) { $flag += " --yes" }

$cmd = "bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/uninstall.sh)`"$flag"
Log "running uninstall inside WSL"
wsl bash -c $cmd
