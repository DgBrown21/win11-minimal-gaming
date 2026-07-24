<#
.SYNOPSIS
    Win11-Minimal-DB first-boot cleanup: removes Edge/OneDrive, aggressively
    disables Windows Update, and confirms Windows Defender still works.

.DESCRIPTION
    Runs once via the answer file's FirstLogonCommands, right after Setup
    finishes. Deliberately narrow in scope — the bulk of this project's
    debloating already happened OFFLINE, at the image level, in
    slim-image.ps1 during the build (before this ISO even existed). This
    script only handles the handful of things that can't be done safely
    offline:

      1. Microsoft Edge removal — a Win32 install baked in via its own
         installer, not a provisioned Appx package. Offline DISM package
         removal of Edge from a retail image is unsupported/unreliable;
         the official uninstaller (used here) is the proven mechanism.
      2. OneDrive removal — same reasoning, same official-uninstaller
         approach.
      3. Windows Update — aggressively disabled. This is the one deliberate
         difference from projects that protect WU: here, only Windows
         Defender is required to keep working. WU services, its scheduled
         task tree, and Delivery Optimization's auto-update policy are all
         turned off.
      4. Windows Defender — safety net. Never disabled by this script;
         actively re-confirmed running/Automatic at the end, the same way
         a WU-protecting script would protect WU.
      5. Steam install + Big Picture autostart. Installed via winget (falls
         back to the official installer if winget's unavailable) and a
         Startup-folder shortcut launches Steam Big Picture automatically
         once the desktop is reached. Big Picture's own "Exit to Desktop"
         always gets you to a normal desktop — no custom shell replacement,
         explorer.exe stays the shell throughout.
      6. Files (files-community/Files) — attempted via winget's msstore
         source as an optional Explorer alternative. Best-effort only: no
         direct MSIX download exists for it, and msstore acquisition may
         require a signed-in Microsoft account this build deliberately
         doesn't have. Failure here is silent/non-fatal.
      7. Windows autologon — enabled for the account this script is running
         as. Paired with the blank password autounattend.xml creates it
         with (see that file's header for the safety reasoning); the net
         effect is boot straight to desktop, then straight into Steam Big
         Picture, no login screen and no manual Steam launch needed.

    HONEST LIMITS:
      - Appx removal already happened offline (slim-image.ps1) — nothing
        Appx-related is repeated here.
      - Edge and OneDrive removal cannot be undone by this script — there's
        no -Undo mode here (unlike the sibling Win11-Install project) since
        this is a one-shot first-boot script for a purpose-built image, not
        a tool meant to be re-run/reversed on an existing install. To bring
        either back: Edge from https://www.microsoft.com/edge, OneDrive
        from https://www.microsoft.com/microsoft-365/onedrive/download.
      - Because Windows Update is disabled here, some older game
        installers/mod tools that expect an on-demand .NET Framework 3.5
        fetch from WU would normally fail — slim-image.ps1 already baked
        NetFx3 into the image offline specifically to avoid that.
#>

$ErrorActionPreference = "Continue"
$LogFile = Join-Path $env:ProgramData "first-boot-tweaks.log"

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must be run as Administrator. Re-launch an elevated PowerShell and try again." "Red"
    exit 1
}

Write-Log "==== first-boot-tweaks.ps1 starting ===="

# ═══════════════════════════════════════════════════════════════════════════
# 1. MICROSOFT EDGE — full removal
# ═══════════════════════════════════════════════════════════════════════════
# WebView2 runtime is deliberately left alone — many unrelated apps
# (including some Store apps and non-Microsoft software) silently depend on
# it being present; removing it breaks things that have nothing to do with
# the Edge browser itself.
Write-Log "=== Microsoft Edge ==="
$edgeSetup = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($edgeSetup) {
    Start-Process $edgeSetup.FullName -ArgumentList "--uninstall --system-level --verbose-logging --force-uninstall" -Wait -ErrorAction SilentlyContinue
    Write-Log "  Ran Edge uninstaller."
} else {
    Write-Log "  Edge installer not found (may already be removed or in a different path)." "Yellow"
}
Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineCore*" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineUA*" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
foreach ($svc in @("edgeupdate", "edgeupdatem")) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}
Write-Log "  Disabled Edge update tasks/services."

# ═══════════════════════════════════════════════════════════════════════════
# 2. ONEDRIVE — full removal
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== OneDrive ==="
Stop-Process -Name "OneDrive" -Force -ErrorAction SilentlyContinue
$oneDriveSetup = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
if (-not (Test-Path $oneDriveSetup)) { $oneDriveSetup = "$env:SystemRoot\System32\OneDriveSetup.exe" }
if (Test-Path $oneDriveSetup) {
    Start-Process $oneDriveSetup -ArgumentList "/uninstall" -Wait -ErrorAction SilentlyContinue
    Write-Log "  Ran OneDriveSetup.exe /uninstall."
}
Remove-Item "$env:LOCALAPPDATA\Microsoft\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:ProgramData\Microsoft OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item "$env:USERPROFILE\OneDrive" -Recurse -Force -ErrorAction SilentlyContinue
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive" -Name "DisableFileSyncNGSC" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "OneDriveSetup" -Value "" -PropertyType String -Force | Out-Null
foreach ($clsid in @(
    "HKCU:\SOFTWARE\Classes\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}",
    "HKCU:\SOFTWARE\Classes\Wow6432Node\CLSID\{018D5C66-4533-4307-9B53-224DE2ED1FE6}"
)) {
    if (-not (Test-Path "$clsid\ShellFolder")) { New-Item -Path "$clsid\ShellFolder" -Force -ErrorAction SilentlyContinue | Out-Null }
    New-ItemProperty -Path "$clsid\ShellFolder" -Name "Attributes" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
}
Write-Log "  Removed OneDrive and blocked auto-reinstall."

# ═══════════════════════════════════════════════════════════════════════════
# 3. WINDOWS UPDATE — aggressive disable
# ═══════════════════════════════════════════════════════════════════════════
# The deliberate difference from a WU-protecting script: only Defender is
# required to keep working here. BITS is left at its default startup type
# (untouched, not disabled) since some game launchers/Delivery-Optimization-
# adjacent features can depend on it being available even with WU itself
# off.
Write-Log "=== Windows Update (aggressive disable) ==="
foreach ($svc in @("wuauserv", "UsoSvc")) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
    Write-Log "  $svc startup -> Disabled (stopped)"
}
Get-ScheduledTask -TaskPath "\Microsoft\Windows\WindowsUpdate\" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Get-ScheduledTask -TaskPath "\Microsoft\Windows\UpdateOrchestrator\" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Write-Log "  Disabled Windows Update scheduled task trees."
if (-not (Test-Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU")) {
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force | Out-Null
}
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Value 1 -PropertyType DWord -Force | Out-Null
Write-Log "  Set NoAutoUpdate policy = 1."

# ═══════════════════════════════════════════════════════════════════════════
# 4. SAFETY NET — confirm Windows Defender is untouched
# ═══════════════════════════════════════════════════════════════════════════
# Not a "change" — this only ever pushes Defender's services/tasks back to
# their normal enabled state, as a guardrail against any unrelated tweak
# above (or a future edit to this script) accidentally catching them.
Write-Log "=== Confirming Windows Defender is enabled (safety net) ==="
foreach ($svc in @("WinDefend", "WdNisSvc", "SecurityHealthService", "wscsvc")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
        if ($s.Status -ne "Running" -and $svc -ne "WdNisSvc") {
            Start-Service -Name $svc -ErrorAction SilentlyContinue
        }
        Write-Log "  Confirmed $svc = Automatic"
    }
}
Get-ScheduledTask -TaskPath "\Microsoft\Windows\Windows Defender\" -ErrorAction SilentlyContinue |
    Enable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Write-Log "  Confirmed Windows Defender scheduled tasks are enabled."

# ═══════════════════════════════════════════════════════════════════════════
# 5. STEAM — install + Big Picture autostart
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Steam ==="
$steamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
if (-not (Test-Path $steamExe)) {
    $winget = Get-Command winget -ErrorAction SilentlyContinue
    $installed = $false
    if ($winget) {
        Write-Log "  Installing Steam via winget..."
        try {
            winget install --id Valve.Steam -e --silent --accept-package-agreements --accept-source-agreements
            $installed = $true
        } catch {
            Write-Log "  winget install failed, falling back to direct download: $_" "Yellow"
        }
    }
    if (-not $installed -or -not (Test-Path $steamExe)) {
        Write-Log "  Downloading the official Steam installer..."
        $installerPath = Join-Path $env:TEMP "SteamSetup.exe"
        Invoke-WebRequest -Uri "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe" -OutFile $installerPath
        Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
    }
}
if (Test-Path $steamExe) {
    Write-Log "  Steam installed at $steamExe"
    $StartupDir = [Environment]::GetFolderPath("Startup")
    $SteamShortcut = Join-Path $StartupDir "Steam - Big Picture.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($SteamShortcut)
    $shortcut.TargetPath = $steamExe
    $shortcut.Arguments = "-start steam://open/bigpicture"
    $shortcut.WorkingDirectory = Split-Path $steamExe
    $shortcut.Description = "Steam Big Picture (auto-start)"
    $shortcut.Save()
    Write-Log "  Created Big Picture autostart shortcut: $SteamShortcut"
} else {
    Write-Log "  Steam install could not be confirmed — check the log and install manually if needed." "Red"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5b. FILES — open-source file manager (files-community/Files), sideloaded
#     via winget's msstore source since it has no direct MSIX download.
# ═══════════════════════════════════════════════════════════════════════════
# UNVERIFIED: acquiring a Store app through winget's msstore source normally
# requires a licensing handshake that historically wants a signed-in
# Microsoft account — this machine intentionally has none (local-only
# blank-password autologon). This may simply fail here. Treated as fully
# non-fatal/best-effort: Explorer remains available regardless, so a failure
# just means no Files shortcut gets created, nothing else breaks.
Write-Log "=== Files (file manager) ==="
try {
    winget install --id 9NGHP3DX8HDX -s msstore -e --silent --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -eq 0) {
        Write-Log "  Files installed via msstore."
    } else {
        Write-Log "  Files install via msstore returned exit code $LASTEXITCODE (likely needs a signed-in Microsoft account) — skipping, Explorer remains the file manager." "Yellow"
    }
} catch {
    Write-Log "  Files install via msstore failed (non-fatal, Explorer remains the file manager): $_" "Yellow"
}

# ═══════════════════════════════════════════════════════════════════════════
# 6. WINDOWS AUTOLOGON — blank-password local account only, see header
# ═══════════════════════════════════════════════════════════════════════════
# Only works safely because the account has a BLANK password (Windows
# restricts blank-password accounts to console/physical logon only, never
# network logon). If a real password is set on this account later,
# autologon just stops working (expected) — remove these three values from
# the Winlogon key to turn it off cleanly instead of fighting it.
Write-Log "=== Autologon ==="
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
$currentUser = "$env:USERNAME"
Set-ItemProperty -Path $WinlogonPath -Name "AutoAdminLogon" -Value "1"
Set-ItemProperty -Path $WinlogonPath -Name "DefaultUserName" -Value $currentUser
Set-ItemProperty -Path $WinlogonPath -Name "DefaultDomainName" -Value "$env:COMPUTERNAME"
Write-Log "  Autologon enabled for local account '$currentUser'."

# ═══════════════════════════════════════════════════════════════════════════
Write-Log "==== first-boot-tweaks.ps1 finished ===="
Write-Log "Manual restore reminders (not scripted, no -Undo mode in this project):" "Cyan"
Write-Log "  - Edge: https://www.microsoft.com/edge" "Cyan"
Write-Log "  - OneDrive: https://www.microsoft.com/microsoft-365/onedrive/download" "Cyan"
Write-Log "  - Windows Update: Settings > Windows Update, or remove the NoAutoUpdate policy value above and re-enable wuauserv/UsoSvc." "Cyan"
Write-Log "  - Autologon: remove AutoAdminLogon/DefaultUserName/DefaultDomainName from $WinlogonPath" "Cyan"
Write-Log "Log saved to $LogFile"
