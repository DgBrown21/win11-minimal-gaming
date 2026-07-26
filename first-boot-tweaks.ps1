<#
.SYNOPSIS
    Win11-Minimal-DB first-boot cleanup: Edge runtime guard + OneDrive remove, aggressively
    disables Windows Update, and confirms Windows Defender still works.

.DESCRIPTION
    Runs once via the answer file's FirstLogonCommands, right after Setup
    finishes. Deliberately narrow in scope — the bulk of this project's
    debloating already happened OFFLINE, at the image level, in
    slim-image.ps1 during the build (before this ISO even existed). This
    script only handles the handful of things that can't be done safely
    offline:

      1. Microsoft Edge — now removed OFFLINE in slim-image.ps1 (Program
         Files folders, SystemApps, provisioned Appx, SOFTWARE/SYSTEM hive
         entries — everything) before the ISO ever exists. This script only
         keeps a runtime guard that cleans per-user protocol associations
         Windows may re-create at first boot, disables EdgeUpdate services/
         tasks, and reasserts the reinstall block.
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
      6. Extra apps via winget (all best-effort/non-fatal): Google Chrome,
         Helium (private browser, set as default via SetUserFTA), Files
         (file manager, set as default via a folder-open override), Git for
         Windows (required by Claude Code), Claude Code, and opencode. winget
         is kept in the image (slim-image.ps1 no longer removes
         DesktopAppInstaller) specifically so these can install.
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
# 1. MICROSOFT EDGE — runtime guard (offline removal is done in slim-image.ps1 STEP 6c)
# ═══════════════════════════════════════════════════════════════════════════
# Edge is now deleted OFFLINE in slim-image.ps1 (folders, SystemApps, Appx
# packages, and registry entries — all before the image ever boots). This
# section is purely a runtime guard: it cleans up any per-user cruft that
# Windows may re-create on first boot (protocol associations, lingering Appx
# registrations), disables the EdgeUpdate services/tasks, and reasserts the
# reinstall block. WebView2 runtime is left alone.
Write-Log "=== Microsoft Edge (offline-removed; runtime guard) ==="
# Per-user cleanup — Windows may re-register these at first boot
@(
    "HKCU:\SOFTWARE\Classes\microsoft-edge"
    "HKCU:\SOFTWARE\Classes\MSEdgeHTM"
    "HKCU:\SOFTWARE\Classes\MSEdgeHTML"
    "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ApplicationAssociationToast\MicrosoftEdge"
) | ForEach-Object { Remove-Item -Path $_ -Recurse -Force -ErrorAction SilentlyContinue }
# Remove any Edge Appx packages that re-registered at login
Get-AppxPackage -AllUsers -Name "*MicrosoftEdge*" -ErrorAction SilentlyContinue |
    Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
# Disable EdgeUpdate tasks and services
Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineCore*" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
Get-ScheduledTask -TaskName "MicrosoftEdgeUpdateTaskMachineUA*" -ErrorAction SilentlyContinue |
    Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
foreach ($svc in @("edgeupdate", "edgeupdatem")) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
}
# Reassert the EdgeUpdate reinstall block live
foreach ($euRoot in @(
    "HKLM:\SOFTWARE\Microsoft\EdgeUpdate",
    "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate"
)) {
    New-Item -Path $euRoot -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $euRoot -Name "DoNotUpdateToEdgeWithChromium" -Value 1 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $euRoot -Name "InstallDefault" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $euRoot -Name "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
}
Write-Log "  Edge per-user associations cleaned; update tasks/services disabled; reinstall block asserted."

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
    @{Path = "\Microsoft\Windows\Application Experience\"; Name = "AitAgent"}
    @{Path = "\Microsoft\Windows\Autochk\"; Name = "Proxy"}
    @{Path = "\Microsoft\Windows\PI\"; Name = "Sqm-Tasks"}
    @{Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClientOnScenarioDownload"}
    @{Path = "\Microsoft\Windows\Clip\"; Name = "License Validation"}
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

# Broader privacy/telemetry surface — reg names/values lifted from AtlasOS
# (Atlas-OS/Atlas, GPLv3), Winhance (memstechtips/Winhance) and winutil
# (ChrisTitusTech/winutil, MIT) — key/value names only, not their code.
# Grouped by what they turn off; all machine-wide policy so they apply
# regardless of which user logs in.
Write-Log "=== Extended privacy/telemetry policy ==="
$TelemetryPolicy = @(
    # Advertising ID (per-app ad targeting)
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\AdvertisingInfo";                 Name = "DisabledByGroupPolicy";              Value = 1 }
    # Tailored experiences / diagnostic-data-driven suggestions
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent";                    Name = "DisableTailoredExperiencesWithDiagnosticData"; Value = 1 }
    # Activity feed / Timeline upload
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                          Name = "EnableActivityFeed";                 Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                          Name = "PublishUserActivities";              Value = 0 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System";                          Name = "UploadUserActivities";               Value = 0 }
    # "Let websites provide locally relevant content" / location platform
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\LocationAndSensors";              Name = "DisableLocation";                    Value = 1 }
    # Windows Error Reporting off entirely
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting";         Name = "Disabled";                           Value = 1 }
    # Feedback prompts / notifications
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection";                  Name = "DoNotShowFeedbackNotifications";     Value = 1 }
    # Handwriting/typing personalization data collection
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization";                    Name = "RestrictImplicitTextCollection";     Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\InputPersonalization";                    Name = "RestrictImplicitInkCollection";      Value = 1 }
    # Speech model-update reporting / online speech
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Speech";                                  Name = "AllowSpeechModelUpdate";             Value = 0 }
    # Cloud/AI: Copilot + Recall off (belt-and-suspenders; apps removed offline)
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot";                  Name = "TurnOffWindowsCopilot";              Value = 1 }
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI";                       Name = "DisableAIDataAnalysis";              Value = 1 }
    # Ads in Settings/Start/Explorer, "get tips/suggestions"
    @{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer";                        Name = "DisableSearchBoxSuggestions";        Value = 1 }
)
foreach ($p in $TelemetryPolicy) {
    New-Item -Path $p.Path -Force -ErrorAction SilentlyContinue | Out-Null
    New-ItemProperty -Path $p.Path -Name $p.Name -Value $p.Value -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
}
# Per-user advertising-ID + suggested-content (current user; Default hive is
# handled offline in slim-image.ps1's CDM step).
New-Item -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\AdvertisingInfo" -Name "Enabled" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-338393Enabled" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353694Enabled" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
New-ItemProperty -Path "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager" -Name "SubscribedContent-353696Enabled" -Value 0 -PropertyType DWord -Force -ErrorAction SilentlyContinue | Out-Null
Write-Log "  Set extended privacy policy (ad ID, activity feed, location, WER, feedback, input/speech, Copilot/Recall, suggestions)."

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
# 3c-p. POWER PLAN — Ultimate/High Performance as the default
# ═══════════════════════════════════════════════════════════════════════════
# A console-style gaming box should never down-clock or sleep mid-session.
# Ultimate Performance (fixed GUID e9a42b02-… — hidden by default, so it's
# duplicated in first to make it selectable) is preferred; if this SKU
# doesn't expose it, fall back to High Performance (SCHEME_MIN). Then pin
# never-sleep / never-display-off and kill USB selective suspend (a common
# cause of controller/headset dropouts).
Write-Log "=== Power plan (performance) ==="
$ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
& powercfg /duplicatescheme $ultimateGuid 2>$null | Out-Null
$active = & powercfg /setactive $ultimateGuid 2>$null
if ($LASTEXITCODE -ne 0) {
    & powercfg /setactive SCHEME_MIN 2>$null | Out-Null   # High performance
    Write-Log "  Ultimate Performance unavailable on this SKU — set High Performance." "Yellow"
} else {
    Write-Log "  Set Ultimate Performance as the active power plan."
}
# Applies to whichever plan is now active (AC + DC): no sleep, no display
# blank, no disk spindown, no USB selective suspend, no hibernate.
& powercfg /change standby-timeout-ac 0   | Out-Null
& powercfg /change standby-timeout-dc 0   | Out-Null
& powercfg /change monitor-timeout-ac 0   | Out-Null
& powercfg /change monitor-timeout-dc 0   | Out-Null
& powercfg /change disk-timeout-ac 0      | Out-Null
& powercfg /change disk-timeout-dc 0      | Out-Null
& powercfg /change hibernate-timeout-ac 0 | Out-Null
& powercfg /change hibernate-timeout-dc 0 | Out-Null
& powercfg /hibernate off 2>$null | Out-Null
# USB selective suspend off (2a737441-… USB settings subgroup, 48e6b7a6-… setting)
& powercfg /setacvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
& powercfg /setdcvalueindex SCHEME_CURRENT 2a737441-1930-4402-8d77-b2bebba308a3 48e6b7a6-50f5-4782-a5d4-53bb8f07e226 0 | Out-Null
& powercfg /setactive SCHEME_CURRENT | Out-Null
Write-Log "  Pinned never-sleep / never-display-off / no USB selective suspend / hibernate off."

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
# Second batch (added with the telemetry-free pass) — all confirmed
# gaming-irrelevant and safe to disable on a single-purpose console box.
# CDPUserSvc and other per-user (per-session) services carry a random
# _xxxxx suffix, so match those by prefix rather than exact name.
$FootprintServices = @(
    "TrkWks"        # Distributed Link Tracking
    "SysMain"       # Superfetch — little gain on an SSD gaming box
    "Spooler"       # Print Spooler — no printer use case
    "CDPSvc"        # Connected Devices Platform (Phone Link)
    "MapsBroker"    # Downloaded Maps Manager
    "lfsvc"         # Geolocation
    "RetailDemo"    # Retail demo mode
    "WalletService" # Microsoft Wallet
    "Fax"           # Fax
    "PhoneSvc"      # Phone / telephony state
    "WbioSrvc"      # Windows Biometric (no fingerprint/face on this box)
    "SEMgrSvc"      # Payments & NFC/SE Manager
    "SCardSvr"      # Smart Card
    "ScDeviceEnum"  # Smart Card Device Enumeration
    "SmsRouter"     # Windows SMS Router
    "PcaSvc"        # Program Compatibility Assistant (also telemetry-adjacent)
    "RemoteRegistry"
)
foreach ($svc in $FootprintServices) {
    Set-Service -Name $svc -StartupType Disabled -ErrorAction SilentlyContinue
    Stop-Service -Name $svc -Force -ErrorAction SilentlyContinue
}
# Per-user template services (disable the template so new sessions don't spawn them)
foreach ($tmpl in @("CDPUserSvc", "MessagingService", "PimIndexMaintenanceSvc", "UserDataSvc", "UnistoreSvc")) {
    Get-Service -Name "$tmpl*" -ErrorAction SilentlyContinue | ForEach-Object {
        Set-Service -Name $_.Name -StartupType Disabled -ErrorAction SilentlyContinue
        Stop-Service -Name $_.Name -Force -ErrorAction SilentlyContinue
    }
}
Write-Log "  Disabled non-gaming services (link tracking, Superfetch, Spooler, Connected Devices, Maps, Geolocation, RetailDemo, Wallet, Fax, Telephony, Biometric, NFC/SmartCard, SMS, PCA, RemoteRegistry + per-user Messaging/Contacts/UserData template services)."

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
# 5a. GAME MODE — boot straight into Big Picture (explorer stays the shell)
# ═══════════════════════════════════════════════════════════════════════════
# ARCHITECTURE (the "JohnMBooth hybrid"): explorer.exe REMAINS the real
# Winlogon\Shell — this does NOT swap the shell. Windows starts the desktop
# (Progman + taskbar + wallpaper) the normal, fully-painted way, and a
# per-user Startup item (Start-GameMode.ps1) launches Steam Big Picture on
# top behind a black splash.
#
# WHY NOT A SHELL SWAP (learned the hard way): the previous design of this
# project registered powershell+GameModeShell.ps1 as the Winlogon\Shell and
# hand-launched explorer. An explorer started that way — especially after Big
# Picture's exclusive-fullscreen released — never took the desktop shell role:
# it came up as a bare File Explorer window, no wallpaper, no taskbar (a black/
# dead desktop). Forcing a display modeset didn't help because the problem was
# never the display; explorer was a child process, not the shell. Keeping
# explorer as the real shell removes that entire bug class: exiting Big Picture
# returns to a desktop Windows has been painting all along.
#
# This is the same conclusion mature launcher-shell projects reached
# independently: quangmach/GameLauncherShell dropped explorer shell-replacement
# in its 2.0 rewrite (explorer artifacts / on-screen-keyboard popups), and
# caffeinateddragonware/windowshandheldmod keeps a real shell and layers the
# launcher on top behind a boot animation. Microsoft's own Xbox "full screen
# experience" on handhelds works the same way conceptually — a game UI over a
# suppressed-but-live desktop, with a "switch to desktop" path back — which is
# exactly the Exit-to-Desktop → real-desktop flow this gives you.
Write-Log "=== Game Mode (Big Picture autostart; explorer stays the shell) ==="
$WinlogonPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon"
# Belt-and-suspenders: make sure nothing left the shell as anything but
# explorer.exe (older images of this project shipped a shell swap here).
Set-ItemProperty -Path $WinlogonPath -Name "Shell" -Value "explorer.exe" -ErrorAction SilentlyContinue
if (Test-Path $steamExe) {
    try {
        $GameModeDir = Join-Path $env:ProgramData "GameMode"
        New-Item -ItemType Directory -Path $GameModeDir -Force | Out-Null

        # The proven launcher (splash → Big Picture → dismiss). Shipped in
        # $OEM$ alongside this script, copied to ProgramData so it survives
        # independent of the setup media.
        $SourceLauncher = "C:\Windows\Setup\Scripts\Start-GameMode.ps1"
        $LauncherScript = Join-Path $GameModeDir "Start-GameMode.ps1"
        if (Test-Path $SourceLauncher) {
            Copy-Item -Path $SourceLauncher -Destination $LauncherScript -Force
        } else {
            Write-Log "  Start-GameMode.ps1 not found in Setup\Scripts — cannot set up autostart." "Red"
            throw "Start-GameMode.ps1 missing"
        }

        # A tiny .cmd wrapper launches the (hidden) launcher — used by both the
        # Startup item and the "Game Mode" desktop shortcut for re-entry.
        $EnterGameModeScript = Join-Path $GameModeDir "Enter-GameMode.cmd"
        @"
@echo off
start "" powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$LauncherScript"
"@ | Set-Content -Path $EnterGameModeScript -Encoding ASCII

        # Startup-folder shortcut = boots straight into Big Picture every login.
        $StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
        New-Item -ItemType Directory -Path $StartupDir -Force -ErrorAction SilentlyContinue | Out-Null
        $shell = New-Object -ComObject WScript.Shell
        foreach ($lnkTarget in @(
            @{ Path = Join-Path $StartupDir "Game Mode.lnk";                 Desc = "Launch Steam Big Picture at login" },
            @{ Path = Join-Path (Join-Path $env:PUBLIC "Desktop") "Game Mode.lnk"; Desc = "Return to Game Mode (Steam Big Picture)" }
        )) {
            $shortcut = $shell.CreateShortcut($lnkTarget.Path)
            $shortcut.TargetPath = $EnterGameModeScript
            $shortcut.WorkingDirectory = Split-Path $steamExe
            $shortcut.IconLocation = $steamExe
            $shortcut.WindowStyle = 7   # minimized — the .cmd window shouldn't flash
            $shortcut.Description = $lnkTarget.Desc
            $shortcut.Save()
        }
        Write-Log "  Set up Big Picture autostart (Startup shortcut) + 'Game Mode' desktop shortcut for re-entry. explorer.exe remains the shell."
    } catch {
        Write-Log "  Failed to set up Game Mode autostart (non-fatal — explorer.exe is the shell, launch Steam manually): $_" "Red"
    }
} else {
    Write-Log "  Skipping Game Mode autostart — Steam was not confirmed installed." "Yellow"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5b. EXTRA APPS — browsers, file manager, AI CLIs (all via winget)
# ═══════════════════════════════════════════════════════════════════════════
# All installed from winget's main community source. winget is deliberately
# KEPT in the image for this (slim-image.ps1 no longer removes
# Microsoft.DesktopAppInstaller). Everything here is best-effort/non-fatal:
# a failed app install just logs and continues — it never aborts first boot.
#   - Google Chrome            Google.Chrome
#   - Helium (private browser) ImputNet.Helium   (set as default — see 5c)
#   - Files (file manager)     Files-Community.Files (set as default — see 5c)
#   - Git for Windows          Git.Git           (REQUIRED by Claude Code — it
#                                                  shells out to Git Bash)
#   - Claude Code (AI CLI)     Anthropic.ClaudeCode
#   - opencode (AI CLI)        SST.opencode
Write-Log "=== Extra apps (winget) ==="
$winget = Get-Command winget -ErrorAction SilentlyContinue
if (-not $winget) {
    Write-Log "  winget not found on this image — cannot install the extra apps. (slim-image.ps1 is supposed to KEEP Microsoft.DesktopAppInstaller; check that.)" "Red"
} else {
    function Install-WingetApp {
        param([string]$Id, [string]$Name)
        Write-Log "  Installing $Name ($Id)..."
        try {
            winget install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity
            if ($LASTEXITCODE -eq 0) {
                Write-Log "    $Name installed."
            } else {
                Write-Log "    $Name install returned exit code $LASTEXITCODE (non-fatal, continuing)." "Yellow"
            }
        } catch {
            Write-Log "    $Name install failed (non-fatal, continuing): $_" "Yellow"
        }
    }
    Install-WingetApp -Id "Google.Chrome"        -Name "Google Chrome"
    Install-WingetApp -Id "ImputNet.Helium"      -Name "Helium browser"
    Install-WingetApp -Id "Files-Community.Files" -Name "Files (file manager)"
    Install-WingetApp -Id "Git.Git"              -Name "Git for Windows (Claude Code prerequisite)"
    Install-WingetApp -Id "Anthropic.ClaudeCode" -Name "Claude Code"
    Install-WingetApp -Id "SST.opencode"         -Name "opencode"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5c. DEFAULT APPS — Helium as default browser, Files as default file manager
# ═══════════════════════════════════════════════════════════════════════════
# Both are best-effort / non-fatal. Runs as the autologon user (Gamer), which
# is correct — these are per-user (HKCU / UserChoice) settings.
Write-Log "=== Default apps ==="

# ── Default browser: Helium via SetUserFTA ──────────────────────────────────
# Windows 11 protects the http/https/.html UserChoice with a per-user hash, so
# a plain registry write is rejected/reverted. SetUserFTA (Christoph Kolbicz's
# free tool, https://kolbi.cz) computes that hash and is the standard way to
# set defaults unattended. Downloaded fresh at first boot over HTTPS from the
# author's site (explicit project choice). Non-fatal if the download or the
# tool fails — the browser just isn't forced-default and Windows will prompt.
try {
    # Resolve the ProgId Helium actually registered (don't hardcode/guess it).
    $heliumProgId = $null
    foreach ($root in @("HKLM:\SOFTWARE\Clients\StartMenuInternet", "HKCU:\SOFTWARE\Clients\StartMenuInternet")) {
        Get-ChildItem $root -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like "*Helium*" } |
            ForEach-Object {
                $assoc = (Get-ItemProperty -Path (Join-Path $_.PSPath "Capabilities\URLAssociations") -Name "https" -ErrorAction SilentlyContinue)."https"
                if ($assoc) { $heliumProgId = $assoc }
            }
    }
    if (-not $heliumProgId) {
        Write-Log "  Helium ProgId not found in the registry (Helium may not have installed) — skipping default-browser step." "Yellow"
    } else {
        Write-Log "  Helium ProgId = $heliumProgId"
        $sufZip = Join-Path $env:TEMP "SetUserFTA.zip"
        $sufDir = Join-Path $env:TEMP "SetUserFTA"
        Invoke-WebRequest -Uri "https://kolbi.cz/SetUserFTA.zip" -OutFile $sufZip -UseBasicParsing
        Expand-Archive -Path $sufZip -DestinationPath $sufDir -Force
        $sufExe = Get-ChildItem -Path $sufDir -Filter "SetUserFTA.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sufExe) {
            foreach ($assocKey in @("https", "http", ".html", ".htm")) {
                & $sufExe.FullName $assocKey $heliumProgId | Out-Null
            }
            Write-Log "  Set Helium as default for https/http/.html/.htm via SetUserFTA."
        } else {
            Write-Log "  SetUserFTA.exe not found after extraction — default-browser step skipped." "Yellow"
        }
    }
} catch {
    Write-Log "  Default-browser step failed (non-fatal): $_" "Yellow"
}

# ── Default file manager: Files via folder-open command override ─────────────
# There is no official "default file manager" setting in Windows. Overriding
# the per-user Directory/Drive "open" command points folder double-clicks at
# Files instead of Explorer. Reversible (delete the HKCU\...\Classes keys);
# Explorer still exists underneath. If this ever misbehaves, Files' own
# Settings > "Set as default file manager" toggle is the guaranteed fallback.
try {
    $filesAlias = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter "files.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $filesAlias) {
        $filesAlias = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WindowsApps" -Filter "*files*.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
    }
    if (-not $filesAlias) {
        Write-Log "  Files launcher alias not found in WindowsApps — skipping default-file-manager step." "Yellow"
    } else {
        $cmd = "`"$($filesAlias.FullName)`" `"%1`""
        foreach ($cls in @("Directory", "Drive")) {
            $cmdKey = "HKCU:\Software\Classes\$cls\shell\open\command"
            New-Item -Path $cmdKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $cmdKey -Name "(default)" -Value $cmd -ErrorAction SilentlyContinue
            # A stale DDE hook on the default verb would otherwise override the command.
            Remove-ItemProperty -Path "HKCU:\Software\Classes\$cls\shell\open" -Name "DelegateExecute" -ErrorAction SilentlyContinue
        }
        Write-Log "  Set Files as the default folder handler (Directory + Drive open command)."
    }
} catch {
    Write-Log "  Default-file-manager step failed (non-fatal, Explorer remains): $_" "Yellow"
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
