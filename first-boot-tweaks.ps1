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
# 3b. TELEMETRY — services & scheduled tasks
# ═══════════════════════════════════════════════════════════════════════════
# Data lifted from Winhance (memstechtips/Winhance, PolyForm Shield license —
# reg key/service names only, not their code) and AtlasOS (Atlas-OS/Atlas,
# GPLv3) — this project previously only touched Edge/OneDrive/WU, never
# general telemetry. WU/Defender's own services and task trees are
# deliberately never referenced here, same separation the rest of this file
# already relies on.
Write-Log "=== Telemetry services & scheduled tasks ==="
foreach ($svc in @("DiagTrack", "dmwappushservice", "OneSyncSvc", "PcaSvc", "WerSvc", "wercplsupport", "diagnosticshub.standardcollector.service")) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
Write-Log "  Disabled telemetry services (DiagTrack, dmwappushservice, OneSyncSvc, PcaSvc, WerSvc, wercplsupport, diagnosticshub.standardcollector.service)."
$TelemetryTasks = @(
    @{Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser"}
    @{Path = "\Microsoft\Windows\Application Experience\"; Name = "ProgramDataUpdater"}
    @{Path = "\Microsoft\Windows\Application Experience\"; Name = "PcaPatchDbTask"}
    @{Path = "\Microsoft\Windows\Application Experience\"; Name = "StartupAppTask"}
    @{Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator"}
    @{Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip"}
    @{Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "KernelCeipTask"}
    @{Path = "\Microsoft\Windows\DiskDiagnostic\"; Name = "Microsoft-Windows-DiskDiagnosticDataCollector"}
    @{Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClient"}
    @{Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClientOnScenarioDownload"}
    @{Path = "\Microsoft\Windows\Windows Error Reporting\"; Name = "QueueReporting"}
    @{Path = "\Microsoft\Windows\AppxDeploymentClient\"; Name = "UCPD velocity"}
    @{Path = "\Microsoft\Windows\Flighting\FeatureConfig\"; Name = "UsageDataReporting"}
)
foreach ($t in $TelemetryTasks) {
    Get-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction SilentlyContinue |
        Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
}
Write-Log "  Disabled telemetry/CEIP scheduled tasks."
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Force -ErrorAction SilentlyContinue | Out-Null
foreach ($kv in @{ AllowTelemetry = 0; MaxTelemetryAllowed = 0 }.GetEnumerator()) {
    New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name $kv.Key -Value $kv.Value -PropertyType DWord -Force | Out-Null
}
New-ItemProperty -Path "HKCU:\SOFTWARE\Policies\Microsoft\Windows\AppCompat" -Name "AITEnable" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
# EventTranscript is the always-on diagnostic logging pipe that keeps
# running even with AllowTelemetry=0 (Windows 11 Pro's real floor — see the
# sibling Win11-Install project's debloat-lockdown.ps1 header for why 0
# doesn't mean 0 on this edition). Disabling the autologger stops it from
# writing at all rather than just asking nicely via policy.
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventTranscript" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\EventTranscript" -Name "EnableEventTranscript" -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\WMI\Autologger\Diagtrack-Listener" -Name "Start" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
Write-Log "  Set telemetry registry policy (AllowTelemetry, EventTranscript, Diagtrack-Listener autologger)."

# ═══════════════════════════════════════════════════════════════════════════
# 3c. GAMING PERFORMANCE TWEAKS
# ═══════════════════════════════════════════════════════════════════════════
# Data lifted from Winhance's GamingAndPerformanceOptimizations — reg key
# names/values only, applied here as plain PowerShell.
Write-Log "=== Gaming performance tweaks ==="
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl" -Name "Win32PrioritySeparation" -Value 38 -PropertyType DWord -Force | Out-Null
$GamesTaskPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
New-Item -Path $GamesTaskPath -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path $GamesTaskPath -Name "Priority" -Value 6 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $GamesTaskPath -Name "GPU Priority" -Value 8 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $GamesTaskPath -Name "Scheduling Category" -Value "High" -PropertyType String -Force | Out-Null
New-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "HKCU:\Software\Microsoft\GameBar" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\Software\Microsoft\GameBar" -Name "ShowStartupPanel" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
# Game DVR/Game Bar overlay off — pure capture/telemetry overhead on a
# machine that's already going straight into Steam.
New-Item -Path "HKCU:\System\GameConfigStore" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0 -PropertyType DWord -Force | Out-Null
New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR" -Name "AllowGameDVR" -Value 0 -PropertyType DWord -Force | Out-Null
Write-Log "  Set Win32PrioritySeparation/Games task priority, HAGS, Game Mode, Game DVR/Bar-overlay off, fullscreen optimizations."

# ═══════════════════════════════════════════════════════════════════════════
# 3d. FOOTPRINT REDUCTION — non-gaming Automatic services
# ═══════════════════════════════════════════════════════════════════════════
# Measured via a live process/service audit on the test VM (2026-07-25):
# ~97 processes / 2.28GB just for the OS + a not-yet-fully-loaded Steam.
# These are Automatic-start services with no gaming relevance, confirmed
# present in that audit's running-services list. Explicitly NOT touched:
# webthreatdefusersvc (Defender SmartScreen — this project's Defender
# safety net covers it) and WpnService/WpnUserService (Defender alert
# toasts may depend on push notifications).
Write-Log "=== Footprint reduction: non-gaming services ==="
foreach ($svc in @("TrkWks", "SysMain", "Spooler", "CDPSvc", "CDPUserSvc")) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
Write-Log "  Disabled: TrkWks (link tracking), SysMain (Superfetch — SSD-era gaming boxes gain little from it), Spooler (no printer use case), CDPSvc/CDPUserSvc (Phone Link / Connected Devices — measured ~47MB via CrossDeviceResume alone)."

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
} else {
    Write-Log "  Steam install could not be confirmed — check the log and install manually if needed." "Red"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5a. GAME MODE SHELL — replaces explorer.exe as the Winlogon shell
# ═══════════════════════════════════════════════════════════════════════════
# REVERSAL from this project's original design: explorer.exe used to stay
# the registered shell, with Steam Big Picture just autostarting via a
# Startup-folder shortcut on top of it (still what the sibling Win11-Install
# project's README used to say too). This now does a real shell swap so the
# machine boots straight into Big Picture, SteamOS-Deck-style, instead of
# landing on a bare desktop first. See game-mode-shell.ps1's own header for
# the full mechanism and the Safe Mode recovery command if this ever needs
# undoing on a machine that's already been imaged.
#
# Researched but not vendored: LifeDreamer24/SteamOS-Shell, jazir555/
# GamesDows, quangmach/GameLauncherShell — all three are small batch/
# VBScript hobby projects, none with a working "jump back into Game Mode
# from the desktop" flow. GamesDows' pre-launch-explorer-hidden technique
# is what game-mode-shell.ps1 borrows (as a technique, not as code — GPLv3,
# not copied); the return-to-Game-Mode piece is simpler than any of them
# attempt: Steam already takes over the screen again on
# `steam://open/bigpicture`, so a plain desktop shortcut is enough.
Write-Log "=== Game Mode shell ==="
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
if (Test-Path $steamExe) {
    try {
        $GameModeDir = Join-Path $env:ProgramData "GameMode"
        New-Item -ItemType Directory -Path $GameModeDir -Force | Out-Null
        $SourceShellScript = "C:\Windows\Setup\Scripts\game-mode-shell.ps1"
        $GameModeShellScript = Join-Path $GameModeDir "GameModeShell.ps1"
        Copy-Item -Path $SourceShellScript -Destination $GameModeShellScript -Force
        Set-ItemProperty -Path $WinlogonPath -Name "Shell" -Value "powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$GameModeShellScript`""
        Write-Log "  Registered $GameModeShellScript as the Winlogon shell."

        # The desktop shortcut can't just launch Steam directly — it also
        # has to flip the persisted mode file back to "game" (see
        # game-mode-shell.ps1's header), or a later reboot would still
        # honor a stale "desktop" state from the last time Big Picture was
        # exited. A tiny .cmd wrapper keeps that logic out of the .lnk
        # itself.
        $EnterGameModeScript = Join-Path $GameModeDir "Enter-GameMode.cmd"
        @"
@echo off
> "%ProgramData%\GameMode\mode.txt" echo game
start "" "$steamExe" -start steam://open/bigpicture
"@ | Set-Content -Path $EnterGameModeScript -Encoding ASCII

        $PublicDesktop = Join-Path $env:PUBLIC "Desktop"
        $GameModeShortcut = Join-Path $PublicDesktop "Game Mode.lnk"
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($GameModeShortcut)
        $shortcut.TargetPath = $EnterGameModeScript
        $shortcut.WorkingDirectory = Split-Path $steamExe
        $shortcut.IconLocation = $steamExe
        $shortcut.WindowStyle = 7  # minimized - the .cmd window shouldn't be visible
        $shortcut.Description = "Return to Game Mode (Steam Big Picture)"
        $shortcut.Save()
        Write-Log "  Created 'Game Mode' desktop shortcut: $GameModeShortcut -> $EnterGameModeScript"
    } catch {
        Write-Log "  Failed to set up the Game Mode shell (non-fatal — explorer.exe remains the shell, Steam must be launched manually): $_" "Red"
    }
} else {
    Write-Log "  Skipping Game Mode shell setup — Steam was not confirmed installed." "Yellow"
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
