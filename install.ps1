# agentbox installer for Windows (PowerShell). Bootstraps WSL and installs
# agentbox inside it.
#
# Usage (PowerShell, run as user):
#   iwr https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/install.ps1 | iex
#
# Or downloaded:
#   .\install.ps1
#
# What it does:
#   1. Checks for WSL. Installs it if missing (`wsl --install`) — REQUIRES REBOOT
#      if WSL wasn't previously enabled. Re-run this script after reboot.
#   2. Ensures a default WSL distro is present (installs Ubuntu via wsl --install -d Ubuntu
#      if no distros exist).
#   3. Runs the agentbox install.sh inside WSL via `wsl bash -c "curl ... | bash"`.
#   4. Tells you how to launch claude/codex/opencode from Windows (via wsl wrappers).
#
# Caveats:
#   - agentbox is fundamentally a bash + openshell tool. Native Windows is not
#     supported; everything runs inside WSL.
#   - The "agent" you interact with from Windows is via WSL. Terminals like
#     Windows Terminal / Alacritty work fine; cmd.exe will be limited.

param(
    [switch]$Yes,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

if ($Help) {
    Get-Content $MyInvocation.MyCommand.Definition | Select-Object -First 30 | ForEach-Object { $_ -replace "^# ?", "" }
    exit 0
}

function Log($msg)   { Write-Host "install.ps1: $msg" -ForegroundColor Cyan }
function Warn($msg)  { Write-Host "install.ps1: $msg" -ForegroundColor Yellow }
function Err($msg)   { Write-Host "install.ps1: $msg" -ForegroundColor Red; exit 1 }
function Ok($msg)    { Write-Host "install.ps1: $msg" -ForegroundColor Green }

# Windows version check
if ([Environment]::OSVersion.Version.Major -lt 10) {
    Err "Windows 10 or newer required for WSL"
}

# Check for WSL
$wslPresent = $false
try {
    $null = wsl --status 2>$null
    if ($LASTEXITCODE -eq 0) { $wslPresent = $true }
} catch {}

if (-not $wslPresent) {
    Warn "WSL is not installed."
    Log "Run this in an Administrator PowerShell to install WSL + the default Ubuntu distro:"
    Write-Host "    wsl --install" -ForegroundColor White
    Log "Reboot when prompted, then re-run this script (as your normal user)."
    exit 1
}

Log "WSL detected"

# Check for installed distros
$distros = (wsl --list --quiet) -replace "\0", "" | Where-Object { $_ -ne "" -and $_ -ne "docker-desktop" -and $_ -ne "docker-desktop-data" }
if ($distros.Count -eq 0) {
    Warn "WSL is installed but no Linux distro is registered."
    Log "Run: wsl --install -d Ubuntu"
    Log "Wait for the install to finish, set up your username/password, then re-run this script."
    exit 1
}

Ok "WSL distro(s) found: $($distros -join ', ')"

# Run agentbox install.sh inside the default WSL distro
$yesArg = if ($Yes) { "AGENTBOX_YES=1 " } else { "" }
$cmd = "${yesArg}bash -c `"`$(curl -fsSL https://raw.githubusercontent.com/vshlpunjabi/agentbox/main/install.sh)`""

Log "running agentbox install inside WSL..."
Log "  $cmd"
wsl bash -c $cmd
if ($LASTEXITCODE -ne 0) {
    Err "agentbox install inside WSL failed (exit $LASTEXITCODE)"
}

Ok "agentbox installed inside WSL"

Write-Host ""
Write-Host @"

Next steps (Windows):

  1. Inside your WSL distro, the shim is on PATH at
     ~/.local/share/agentbox/bin/{claude,codex,opencode,agentbox}.
     Add to your WSL shell rc:
        export PATH="`$HOME/.local/share/agentbox/bin:`$PATH"

  2. To launch the agent from a Windows terminal (Windows Terminal,
     Alacritty, etc.), run:
        wsl bash -lc "claude"
     or just open a WSL shell and use claude/codex/opencode there.

  3. One-time setup inside WSL:
        wsl bash -lc "agentbox doctor"
        wsl bash -lc "agentbox auth setup claude"
        wsl bash -lc "agentbox notify setup"

  Notes:
    - Docker Desktop's WSL2 integration is required (Docker Desktop -> Settings ->
      Resources -> WSL integration -> enable for your distro).
    - alerter is macOS-only; on Linux/WSL the watcher uses zenity/notify-send/
      terminal prompt. Install zenity inside WSL for graphical Allow/Deny:
        wsl sudo apt install -y zenity libnotify-bin

  Source + docs: https://github.com/vshlpunjabi/agentbox

"@
