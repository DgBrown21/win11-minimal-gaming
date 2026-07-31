<#
.SYNOPSIS
    One-shot "make me the ISO" launcher for Win11-Minimal.

.DESCRIPTION
    Does everything the manual build needs, in order, with no prior setup:

      1. Self-elevates (prompts for admin via UAC) — the build servicing
         stage needs Administrator for DISM / Mount-WindowsImage.
      2. Makes sure oscdimg.exe exists; if not, installs the free Windows
         ADK "Deployment Tools" via winget and locates it.
      3. Runs build-windows.ps1, writing the finished Win11-Minimal.iso
         straight into your Downloads folder (override with -OutDir).

    Just double-click Build-Iso.cmd (or right-click this file > Run with
    PowerShell). The window stays open at the end so you can read the
    result or any error.

    The build downloads an ~8.5GB Windows 11 ISO from Microsoft and runs a
    servicing pass, so expect it to run a while. The pipeline is still
    UNVERIFIED end-to-end (see README) — boot-test the ISO in a VM before
    using it on real hardware.

.PARAMETER OutDir
    Where to write Win11-Minimal.iso. Defaults to your Downloads folder.

.PARAMETER SkipDownload
    Reuse an already-downloaded build\windows11.iso instead of fetching it
    again (handshake links expire in ~24h).

.PARAMETER WinSkuId
    Passed through to build-windows.ps1 (ISO language/edition SKU id).
#>
param(
    [string]$OutDir = (Join-Path $env:USERPROFILE "Downloads"),
    [switch]$SkipDownload,
    [string]$WinSkuId
)

$ErrorActionPreference = "Stop"

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ── 1. Self-elevate ────────────────────────────────────────────────────────
# If we're not admin, relaunch this same script elevated (UAC prompt) and let
# the elevated copy do the work. This first copy just hands off and exits.
if (-not (Test-Admin)) {
    Write-Host "==> Requesting administrator rights (needed for DISM image servicing)..." -ForegroundColor Cyan
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-OutDir", "`"$OutDir`"")
    if ($SkipDownload) { $argList += "-SkipDownload" }
    if ($WinSkuId)     { $argList += @("-WinSkuId", $WinSkuId) }
    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argList
        Write-Host "    An elevated window is opening to run the build." -ForegroundColor Cyan
    } catch {
        Write-Host "[ERR] Elevation was cancelled. Re-run and accept the UAC prompt." -ForegroundColor Red
    }
    return
}

# ═══════════════════════════════════════════════════════════════════════════
# From here on we are elevated. Wrap everything so the window stays open with
# the result / error visible (this copy is usually a double-click child).
# ═══════════════════════════════════════════════════════════════════════════
try {
    $RepoDir   = $PSScriptRoot
    $BuildScript = Join-Path $RepoDir "build-windows.ps1"
    if (-not (Test-Path $BuildScript)) {
        throw "build-windows.ps1 was not found next to this launcher ($RepoDir). Keep Build-Iso.ps1 in the repo root."
    }

    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    $OutDir = (Resolve-Path $OutDir).Path

    # ── 2. Ensure oscdimg.exe (Windows ADK Deployment Tools) ───────────────
    function Find-Oscdimg {
        $std = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe"
        if (Test-Path $std) { return $std }
        foreach ($root in @("${env:ProgramFiles(x86)}\Windows Kits\10", "${env:ProgramFiles}\Windows Kits\10")) {
            if (Test-Path $root) {
                $hit = Get-ChildItem -Path $root -Recurse -Filter "oscdimg.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($hit) { return $hit.FullName }
            }
        }
        return $null
    }

    $oscdimg = Find-Oscdimg
    if (-not $oscdimg) {
        Write-Host "==> oscdimg.exe not found — installing the Windows ADK (Deployment Tools) via winget..." -ForegroundColor Cyan
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw "winget isn't available on this machine. Install the Windows ADK 'Deployment Tools' feature manually from https://learn.microsoft.com/windows-hardware/get-started/adk-install then re-run."
        }
        & winget install --id Microsoft.WindowsADK -e --accept-source-agreements --accept-package-agreements
        $oscdimg = Find-Oscdimg
        if (-not $oscdimg) {
            throw "The ADK install finished but oscdimg.exe still isn't present. Make sure the 'Deployment Tools' feature was selected, then re-run."
        }
    }
    Write-Host "    oscdimg: $oscdimg" -ForegroundColor DarkGray

    # ── 3. Build ───────────────────────────────────────────────────────────
    Write-Host "==> Building Win11-Minimal.iso -> $OutDir" -ForegroundColor Cyan
    Write-Host "    (downloads ~8.5GB from Microsoft + runs a servicing pass — this takes a while)" -ForegroundColor DarkGray
    $buildArgs = @("-OscdimgPath", $oscdimg, "-OutDir", $OutDir)
    if ($SkipDownload) { $buildArgs += "-SkipDownload" }
    if ($WinSkuId)     { $buildArgs += @("-WinSkuId", $WinSkuId) }
    & $BuildScript @buildArgs

    $finalIso = Join-Path $OutDir "Win11-Minimal.iso"
    Write-Host ""
    if (Test-Path $finalIso) {
        $gb = [math]::Round((Get-Item $finalIso).Length / 1GB, 2)
        Write-Host "==> DONE. ISO created: $finalIso (${gb}GB)" -ForegroundColor Green
    } else {
        Write-Host "[WARN] Build finished but $finalIso wasn't found — check the output above." -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "[ERR] $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ""
    Write-Host "Press Enter to close..." -ForegroundColor DarkGray
    [void](Read-Host)
}
