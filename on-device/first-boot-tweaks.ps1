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
      6. Web browser — Helium, the machine's ONLY browser now that Edge is
         removed offline, so it gets a GUARANTEED install: winget first, then a
         fallback to its official signed installer from GitHub (latest resolved
         via the GitHub API, run silently), and it's set as the default browser
         via SetUserFTA. Plus best-effort/non-fatal extra apps via winget:
         Google Chrome, Files (file manager, set as default via a folder-open
         override), Git for Windows (required by Claude Code), Claude Code, and
         opencode. winget is kept in the image (slim-image.ps1 no longer removes
         DesktopAppInstaller) specifically so these can install.
      7. Windows autologon — enabled for the account this script is running
         as. Paired with the blank password autounattend.xml creates it
         with (see that file's header for the safety reasoning); the net
         effect is boot straight to desktop, then straight into Steam Big
         Picture, no login screen and no manual Steam launch needed.
      8. Latest GPU drivers — because Windows Update is disabled here, the
         GPU driver (the one that actually matters on a gaming box) is
         fetched straight from the vendor: NVIDIA's latest Game Ready Driver
         resolved + silent-installed via NVIDIA's public lookup API, Intel's
         official Driver & Support Assistant via winget, and AMD's auto-detect
         installer staged on the desktop (AMD has no unattended path). Vendor
         detected live via Win32_VideoController; all best-effort/non-fatal.
      9. Boot loader + first-boot Big Picture launch. A fullscreen, topmost
         "GAMING" splash (Show-BootLoader.ps1) covers the desktop for the whole
         first-boot install phase, showing a spinning progress ring and a live
         status line of what's installing. At the end this script launches Big
         Picture itself and then dismisses the loader — so the FIRST boot ends
         in Steam too, not just every boot after it (the Startup shortcut only
         fires from the second login onward).

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

# Set by the boot-loader bootstrap below once the status file exists. Until
# then Set-BootStatus is a no-op, so Write-Log is safe to call before it.
$script:BootStatusFile = $null
function Set-BootStatus {
    param([string]$Text)
    if (-not $script:BootStatusFile) { return }
    # FileShare.ReadWrite so the loader's ~30 Hz polling never blocks this write
    # (and vice versa) — critical for the "__DONE__" sentinel getting through.
    try {
        $fs = [System.IO.File]::Open($script:BootStatusFile, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            $sw = New-Object System.IO.StreamWriter($fs)
            $sw.Write($Text); $sw.Flush()
        } finally { $fs.Dispose() }
    } catch {}
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue
    # Mirror section headers ("=== Foo ===", exactly three '=') onto the
    # fullscreen loader as the live "what's happening now" status line.
    if ($Message -match '^===\s(.+?)\s===$') { Set-BootStatus $Matches[1] }
}

# ═══════════════════════════════════════════════════════════════════════════
# INSTALL-PHASE READINESS HELPERS — the #1 reason "nothing installed" on a real
# first boot. During OOBE FirstLogonCommands the network stack may not be up
# yet, and `winget` is frequently NOT resolvable as a bare command: its
# WindowsApps alias isn't on PATH and the App Installer package may not be
# registered for this session. Either one makes every download / winget call
# silently no-op. These resolve winget by REAL path (with a registration nudge
# and retry) and wait for actual connectivity before anything tries to install.
# ═══════════════════════════════════════════════════════════════════════════
$script:WingetExe   = $null
$script:HaveNetwork = $false

function Wait-ForNetwork {
    param([int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        try { if (Test-Connection -ComputerName "8.8.8.8" -Count 1 -Quiet -ErrorAction SilentlyContinue) { return $true } } catch {}
        try {
            $r = Invoke-WebRequest -Uri "http://www.msftconnecttest.com/connecttest.txt" -UseBasicParsing -TimeoutSec 5 -ErrorAction Stop
            if ($r.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds 5
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Resolve-WingetExe {
    param([int]$TimeoutSec = 240)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        # Preferred: the real winget.exe inside the registered App Installer
        # package (avoids the WindowsApps ACL / PATH-alias problems entirely).
        $pkg = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($pkg -and $pkg.InstallLocation) {
            $candidate = Join-Path $pkg.InstallLocation "winget.exe"
            if (Test-Path $candidate) { return $candidate }
        }
        # Next: glob the package folder directly.
        $exe = Get-ChildItem "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending | Select-Object -First 1
        if ($exe) { return $exe.FullName }
        # Last: PATH, if it happens to be there.
        $cmd = Get-Command winget.exe -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        # Still nothing — nudge per-user registration of the App Installer and retry.
        $srcPkgs = if ($pkg) { @($pkg) } else { Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue }
        foreach ($sp in $srcPkgs) {
            try { Add-AppxPackage -DisableDevelopmentMode -Register "$($sp.InstallLocation)\AppXManifest.xml" -ErrorAction SilentlyContinue } catch {}
        }
        Start-Sleep -Seconds 6
    } while ((Get-Date) -lt $deadline)
    return $null
}

function Install-WingetApp {
    param([string]$Id, [string]$Name)
    if (-not $script:HaveNetwork) { Write-Log "    Skipping $Name — no network." "Yellow"; return $false }
    if (-not $script:WingetExe)   { Write-Log "    Skipping $Name — winget unavailable." "Yellow"; return $false }
    Write-Log "  Installing $Name ($Id)..."
    try {
        & $script:WingetExe install --id $Id -e --silent --accept-package-agreements --accept-source-agreements --disable-interactivity | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Log "    $Name installed."; return $true }
        Write-Log "    $Name install returned exit code $LASTEXITCODE (non-fatal, continuing)." "Yellow"; return $false
    } catch {
        Write-Log "    $Name install failed (non-fatal, continuing): $_" "Yellow"; return $false
    }
}

# Small download helper — every fetch below wants the same "silence the progress
# bar (it makes Invoke-WebRequest crawl) then restore it" dance, so do it once
# here instead of repeating it at each call site. try/finally always restores.
function Get-File {
    param([string]$Uri, [string]$OutFile, [int]$TimeoutSec = 600)
    $old = $ProgressPreference
    $ProgressPreference = "SilentlyContinue"
    try { Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec }
    finally { $ProgressPreference = $old }
}

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "This script must be run as Administrator. Re-launch an elevated PowerShell and try again." "Red"
    exit 1
}

Write-Log "==== first-boot-tweaks.ps1 starting ===="

# ═══════════════════════════════════════════════════════════════════════════
# 0. BOOT LOADER — cover the desktop with the animated "GAMING" splash NOW
# ═══════════════════════════════════════════════════════════════════════════
# First boot does a lot of visible work (driver + Steam + app installs) on a
# freshly-painted desktop. The GAMING splash must cover it the whole time.
#
# To kill the desktop flash at the very start, the answer file launches the
# loader as its OWN FirstLogonCommand (Order 1) — a fast, tiny command — BEFORE
# this heavier script (Order 2) even starts, so the splash is already up. So the
# first thing to do here is ADOPT that already-running loader (grab its process
# handle so we can drive its status file and close it at the end) rather than
# launch a second splash on top of it. If for any reason no loader is running
# (older answer file, it failed to start), fall back to launching one now.
# Entirely non-fatal: if there's no loader at all, first boot just runs on the
# visible desktop as before.
$GameModeDir = Join-Path $env:ProgramData "GameMode"
New-Item -ItemType Directory -Path $GameModeDir -Force -ErrorAction SilentlyContinue | Out-Null
$script:BootStatusFile = Join-Path $GameModeDir "boot-status.txt"
Set-BootStatus "Preparing Game Mode..."
$loaderProc = $null
try {
    # Adopt the loader the answer file's Order-1 command already started.
    $existing = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*Show-BootLoader.ps1*" } | Select-Object -First 1
    if ($existing) {
        $loaderProc = Get-Process -Id $existing.ProcessId -ErrorAction SilentlyContinue
        Write-Log "Adopted the already-running boot loader (PID $($existing.ProcessId)) — desktop was covered from the first frame."
    }
    if (-not $loaderProc) {
        # Fallback: no loader running yet — start one from the copy in ProgramData.
        $srcLoader    = "C:\Windows\Setup\Scripts\Show-BootLoader.ps1"
        $LoaderScript = Join-Path $GameModeDir "Show-BootLoader.ps1"
        if (Test-Path $srcLoader) { Copy-Item -Path $srcLoader -Destination $LoaderScript -Force }
        if (Test-Path $LoaderScript) {
            $loaderProc = Start-Process powershell.exe -PassThru -ArgumentList @(
                "-NoLogo","-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass",
                "-File","`"$LoaderScript`"","-StatusFile","`"$script:BootStatusFile`""
            )
            Write-Log "Boot loader launched (PID $($loaderProc.Id)) — desktop is covered for first boot."
        } else {
            Write-Log "Show-BootLoader.ps1 not found in Setup\Scripts — continuing without the fullscreen splash (non-fatal)." "Yellow"
        }
    }
    # Keep a ProgramData copy regardless (Start-GameMode.ps1 loads it from there
    # for every subsequent login).
    $srcLoaderCopy = "C:\Windows\Setup\Scripts\Show-BootLoader.ps1"
    if (Test-Path $srcLoaderCopy) {
        Copy-Item -Path $srcLoaderCopy -Destination (Join-Path $GameModeDir "Show-BootLoader.ps1") -Force -ErrorAction SilentlyContinue
    }
} catch {
    Write-Log "Could not set up the boot loader (non-fatal, first boot runs on the visible desktop): $_" "Yellow"
}

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
# 3d-net. CONNECTIVITY & WINGET READINESS — gate before anything downloads
# ═══════════════════════════════════════════════════════════════════════════
# Everything below (drivers, Steam, browser, apps) needs the network up AND
# winget resolvable. Neither is guaranteed this early in first boot, so wait
# for them explicitly here — this is what makes the installs below actually run
# instead of silently no-op'ing (the "nothing installed" bug).
Write-Log "=== Waiting for network ==="
$script:HaveNetwork = Wait-ForNetwork -TimeoutSec 300
if ($script:HaveNetwork) {
    Write-Log "  Network is up."
} else {
    Write-Log "  No internet after 5 min — downloads/installs will be SKIPPED. Connect to a network (OOBE should have shown the Wi-Fi/network page; a wired LAN cable also works) and re-run C:\Windows\Setup\Scripts\first-boot-tweaks.ps1 to finish app setup." "Red"
}
Write-Log "=== Resolving winget ==="
$script:WingetExe = Resolve-WingetExe -TimeoutSec 240
if ($script:WingetExe) {
    Write-Log "  winget resolved at: $script:WingetExe"
} else {
    Write-Log "  winget could not be resolved at first boot — winget-only apps (Chrome, Files, Git, Claude Code, opencode) will be skipped; Steam/Helium fall back to their direct installers." "Yellow"
}

# ═══════════════════════════════════════════════════════════════════════════
# 3e. LATEST GPU DRIVERS — fetch straight from the vendor (WU is disabled here)
# ═══════════════════════════════════════════════════════════════════════════
# Because Windows Update is turned OFF above, Windows won't pull GPU drivers
# from its online driver catalog the way a normal install does — so on a
# gaming box, the one driver that actually matters has to be fetched here.
# GPU vendors ONLY by design (no chipset/NIC/audio); detected live via
# Win32_VideoController. Every branch is best-effort / NON-FATAL: any failure
# logs a manual download link and first boot keeps going.
Write-Log "=== Latest GPU drivers ==="
$gpus = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -and $_.PNPDeviceID -like "PCI\*" })
if (-not $gpus) {
    Write-Log "  No PCI display adapter detected (VM / basic display adapter?) — skipping GPU driver fetch." "Yellow"
} else {
    # Map each detected adapter to a vendor bucket (a box can have an iGPU +
    # dGPU, so more than one may fire).
    $vendors = @{}
    foreach ($g in $gpus) {
        $hay = "$($g.Name) $($g.AdapterCompatibility)"
        if     ($hay -match "NVIDIA")                       { $vendors["NVIDIA"] = $g.Name }
        elseif ($hay -match "AMD|Advanced Micro|Radeon")    { $vendors["AMD"]    = $g.Name }
        elseif ($hay -match "Intel")                        { $vendors["Intel"]  = $g.Name }
    }
    if (-not $vendors.Count) {
        Write-Log "  Display adapter(s) found but vendor unrecognized: $($gpus.Name -join ', '). Skipping." "Yellow"
    } else {
        Write-Log "  Detected GPU vendor(s): $($vendors.Keys -join ', ')"
    }

    # ── NVIDIA — latest Game Ready Driver via NVIDIA's public lookup API ───────
    # No NVIDIA GPU driver ships in winget, so resolve the newest Game Ready
    # Driver straight from NVIDIA's public driver-lookup API (the same endpoints
    # the open-source TinyNvidiaUpdateChecker uses). The product-series / product
    # IDs are DISCOVERED from the detected adapter name at runtime — only the OS
    # id and the API URLs are constants — so a brand-new card generation needs no
    # code change. Fragile by nature (it's an undocumented public API): if NVIDIA
    # changes it, the whole block just logs the manual link and moves on.
    if ($script:HaveNetwork -and $vendors.ContainsKey("NVIDIA")) {
        $nvName = $vendors["NVIDIA"]
        Write-Log "  [NVIDIA] $nvName — resolving latest Game Ready Driver..."
        try {
            $lookupBase = "https://www.nvidia.com/Download/API/lookupValueSearch/"
            function Get-NvLookup {
                param([int]$TypeID, [string]$ParentID)
                $uri = "$lookupBase`?TypeID=$TypeID"
                if ($ParentID) { $uri += "&ParentID=$ParentID" }
                (Invoke-RestMethod -Uri $uri -UseBasicParsing -TimeoutSec 30).LookupValueSearch.LookupValues
            }
            # Pull the model out of the adapter name, e.g. "RTX 4070" / "GTX 1660".
            if ($nvName -notmatch "(RTX|GTX|GT|MX)\s*0*([0-9]{3,4})") {
                throw "Could not parse an NVIDIA model number from '$nvName'."
            }
            $nvPrefix = $Matches[1]                       # RTX / GTX / ...
            $nvModel  = $Matches[2]                        # e.g. 4070
            $nvGen    = if ($nvModel.Length -ge 4) { $nvModel.Substring(0,2) } else { $nvModel.Substring(0,1) }  # 4070->40, 970->9
            Write-Log "    Parsed model: $nvPrefix $nvModel (series generation '$nvGen')."

            # 1) Product Type -> GeForce
            $ptype = Get-NvLookup -TypeID 1 | Where-Object { $_.Name -match "GeForce" } | Select-Object -First 1
            if (-not $ptype) { throw "GeForce product type not found in NVIDIA lookup." }
            # 2) Product Series (psid) — e.g. "GeForce RTX 40 Series"
            $series = Get-NvLookup -TypeID 2 -ParentID $ptype.Value |
                Where-Object { $_.Name -match [regex]::Escape($nvPrefix) -and $_.Name -match "\b$nvGen\b.*Series" } |
                Select-Object -First 1
            if (-not $series) { throw "No matching product series for '$nvPrefix $nvGen Series'." }
            # 3) Product (pfid) — the specific card, matched by full model number
            $product = Get-NvLookup -TypeID 3 -ParentID $series.Value |
                Where-Object { $_.Name -match "\b$nvModel\b" } | Select-Object -First 1
            if (-not $product) {
                # Fall back to any product in the series so we still get a WHQL driver
                $product = Get-NvLookup -TypeID 3 -ParentID $series.Value | Select-Object -First 1
                if ($product) { Write-Log "    Exact model not listed; using series driver ($($product.Name))." "Yellow" }
            }
            if (-not $product) { throw "No product entry under series '$($series.Name)'." }
            Write-Log "    NVIDIA IDs -> psid=$($series.Value) pfid=$($product.Value) ($($series.Name) / $($product.Name))."

            # 4) Driver lookup. osID 135 = Windows 11 x64 (DCH). dch=1 = DCH driver.
            $ajax = "https://gfwsl.geforce.com/services_toolkit/services/com/nvidia/services/AjaxDriverService.php"
            $q = "func=DriverManualLookup&psid=$($series.Value)&pfid=$($product.Value)&osID=135&languageCode=1033&isWHQL=1&dch=1&sort1=0&numberOfResults=1"
            $drv = Invoke-RestMethod -Uri "$ajax`?$q" -UseBasicParsing -TimeoutSec 30
            $info = $drv.IDS[0].downloadInfo
            if (-not $info -or -not $info.DownloadURL) { throw "NVIDIA lookup returned no download URL." }
            Write-Log "    Latest Game Ready Driver: v$($info.Version)"

            # 5) Download + silent install. The full DCH installer .exe accepts
            #    -s (silent) -clean (clean install) -noreboot directly.
            $nvExe = Join-Path $env:TEMP "nvidia-$($info.Version)-driver.exe"
            Write-Log "    Downloading $($info.DownloadURL) ..."
            Get-File -Uri $info.DownloadURL -OutFile $nvExe -TimeoutSec 1800
            Write-Log "    Installing NVIDIA driver silently (-s -clean -noreboot)..."
            $p = Start-Process -FilePath $nvExe -ArgumentList "-s","-clean","-noreboot" -Wait -PassThru
            Write-Log "    NVIDIA driver installer exit code: $($p.ExitCode) (a reboot may be needed to fully apply)."
        } catch {
            Write-Log "    [NVIDIA] Auto driver fetch failed (non-fatal): $_" "Yellow"
            Write-Log "    Install the latest manually from https://www.nvidia.com/download/index.aspx" "Cyan"
        }
    }

    # ── AMD — silent install via the installer's -INSTALL switch ──────────────
    # AMD's consumer Adrenalin driver isn't in winget (only the wrong
    # 'AMD Software: Cloud Edition' enterprise SKU is). The auto-detect tool has
    # no unattended path, but the full/minimal SETUP package DOES: the Radeon
    # Software Command Line Installation guide documents `-INSTALL`, which
    # installs silently (no GUI, no output). So instead of just staging a GUI
    # installer for the user to run (the old behaviour — which meant AMD boxes
    # got NO driver, and therefore no HDMI/DisplayPort audio either), download
    # the web setup and run it with -INSTALL. If that doesn't take, the same
    # installer is left on the desktop as a manual fallback.
    if ($script:HaveNetwork -and $vendors.ContainsKey("AMD")) {
        Write-Log "  [AMD] $($vendors['AMD']) — downloading AMD Software: Adrenalin Edition and installing silently."
        try {
            # NOTE: AMD has no stable version-less installer URL, so this is a
            # pinned Adrenalin web-setup link and WILL age out over time. That's
            # intentionally harmless: if it 404s, the catch below just logs the
            # amd.com/support link instead. Bump the version when refreshing
            # (latest known good as of 2026-07: 26.7.1).
            $amdUrl = "https://drivers.amd.com/drivers/installer/26.7/whql/amd-software-adrenalin-edition-26.7.1-minimalsetup-260724_web.exe"
            $amdExe = Join-Path $env:TEMP "amd-adrenalin-web-setup.exe"
            Get-File -Uri $amdUrl -OutFile $amdExe -TimeoutSec 600

            # -INSTALL = unattended install (the web setup fetches the full
            # package first, so give it a generous cap and don't block forever).
            Write-Log "    Installing AMD driver silently (-INSTALL) — the web setup downloads the full package first, this can take several minutes."
            $p = Start-Process -FilePath $amdExe -ArgumentList "-INSTALL" -PassThru
            if ($p.WaitForExit(1500000)) {   # up to 25 min
                Write-Log "    AMD installer exit code: $($p.ExitCode) (a reboot may be needed to fully apply)."
            } else {
                Write-Log "    AMD silent install exceeded 25 min — killing it; the installer is left on the desktop to finish manually." "Yellow"
                try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
            }

            # Fallback safety net: drop the same installer on the Public Desktop
            # so it can be run by hand if the silent install didn't land (e.g. a
            # card that needs a reboot mid-install).
            try {
                $amdDesktop = Join-Path (Join-Path $env:PUBLIC "Desktop") "Install AMD Graphics Driver.exe"
                Copy-Item -Path $amdExe -Destination $amdDesktop -Force -ErrorAction SilentlyContinue
                Write-Log "    Left a copy on the desktop ('Install AMD Graphics Driver.exe') in case a manual run is needed." "Cyan"
            } catch {}
        } catch {
            Write-Log "    [AMD] Auto driver install failed (non-fatal): $_" "Yellow"
            Write-Log "    Get the latest Adrenalin driver from https://www.amd.com/en/support" "Cyan"
        }
    }

    # ── Intel — official Driver & Support Assistant (winget) ───────────────────
    # Intel's supported route for graphics driver updates is the Driver &
    # Support Assistant, which IS in winget. It installs headless, then updates
    # the Intel GPU driver from its own service. Best-effort / non-fatal.
    if ($script:HaveNetwork -and $vendors.ContainsKey("Intel")) {
        Write-Log "  [Intel] $($vendors['Intel']) — installing Intel Driver & Support Assistant (it scans for GPU driver updates on launch)."
        if (-not (Install-WingetApp -Id "Intel.IntelDriverAndSupportAssistant" -Name "Intel Driver & Support Assistant")) {
            Write-Log "    If that didn't take, get Intel drivers from https://www.intel.com/content/www/us/en/download-center/home.html" "Cyan"
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 3f. DRIVER UPDATES — non-GPU drivers now + a weekly check (WU-off-safe)
# ═══════════════════════════════════════════════════════════════════════════
# The GPU step above only handles the graphics driver. Everything else the
# machine needs — chipset, NIC, Bluetooth, storage, the motherboard audio
# codec — normally arrives through Windows Update, which section 3 turned off.
# Update-Drivers.ps1 restores JUST the driver path (it drives the Windows
# Update Agent COM API filtered to Type='Driver', so it never pulls a feature
# or quality OS update) and briefly starts wuauserv only for the query, then
# puts it back to Disabled. Two things happen here:
#   1. Run it once now (-Auto) to install any drivers the image is missing.
#   2. Register a WEEKLY task that scans and, if drivers are offered, pops a
#      window letting the user choose to install (-Notify). Nothing installs
#      automatically after first boot; the user always gets the choice.
Write-Log "=== Driver updates (WU driver catalog, WU otherwise off) ==="
try {
    $DriverDir    = Join-Path $env:ProgramData "DriverUpdate"
    New-Item -ItemType Directory -Path $DriverDir -Force | Out-Null
    $SrcUpdater   = "C:\Windows\Setup\Scripts\Update-Drivers.ps1"
    $DriverScript = Join-Path $DriverDir "Update-Drivers.ps1"
    if (Test-Path $SrcUpdater) {
        Copy-Item -Path $SrcUpdater -Destination $DriverScript -Force
        Write-Log "  Staged Update-Drivers.ps1 to $DriverScript."

        # 1. One-off unattended pass now to catch the non-GPU drivers. Only
        #    worth attempting if the network came up earlier; otherwise the
        #    weekly task will get to it. Non-fatal either way.
        if ($script:HaveNetwork) {
            Write-Log "  Running a one-off driver install pass (-Auto)..."
            $p = Start-Process -FilePath "powershell.exe" `
                -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$DriverScript`"", "-Auto") `
                -Wait -PassThru -WindowStyle Hidden
            Write-Log "    Driver install pass exit code: $($p.ExitCode) (see $DriverDir\driver-update.log for detail)."
        } else {
            Write-Log "  No network — skipping the one-off driver pass; the weekly task will handle it." "Yellow"
        }

        # 2. Weekly check. Interactive + Highest so it can both run the COM
        #    installer (needs admin) AND show the install window on the desktop.
        #    -Notify stays silent unless drivers are actually offered.
        $taskUser = "$env:USERDOMAIN\$env:USERNAME"
        try {
            $drvAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$DriverScript`" -Notify"
            # RandomDelay (a TRIGGER property) spreads the run off a hard 1PM spike.
            $drvTrigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 1:00PM -RandomDelay ([TimeSpan]::FromMinutes(30))
            $drvPrincipal = New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Highest
            # StartWhenAvailable makes a powered-off box catch up its missed run
            # the next time it's on.
            $drvSettings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::FromHours(2))
            Register-ScheduledTask -TaskName "MinimalGaming-DriverCheck" -Action $drvAction -Trigger $drvTrigger `
                -Principal $drvPrincipal -Settings $drvSettings -Force -ErrorAction Stop | Out-Null
            Write-Log "  Registered weekly task 'MinimalGaming-DriverCheck' (Sundays ~1PM) to scan and offer driver updates."
        } catch {
            Write-Log "  Could not register the weekly driver-check task (non-fatal): $_" "Yellow"
        }
    } else {
        Write-Log "  Update-Drivers.ps1 not found in Setup\Scripts — skipping driver-update setup." "Yellow"
    }
} catch {
    Write-Log "  Driver-update setup failed (non-fatal): $_" "Yellow"
}

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
# 4b. AUDIO — safety net (make sure the sound stack is actually running)
# ═══════════════════════════════════════════════════════════════════════════
# "No sound" on a minimal build has two usual causes, both handled here/nearby:
#   1. HDMI / DisplayPort audio comes from the GPU driver. On an AMD box that
#      driver never installed before (it was only staged on the desktop) — the
#      -INSTALL fix in the GPU-driver step above is what restores those audio
#      endpoints. Nothing to do here for that beyond installing the driver.
#   2. The core audio SERVICES not running. This build never disables them, but
#      assert them anyway (Automatic + started) as cheap insurance — a machine
#      with a working audio driver but a stopped Audiosrv/AudioEndpointBuilder
#      shows exactly the same "no audio devices" symptom. RpcSs is their
#      dependency, so confirm it too (it's Automatic by default; never disable).
# If, after this and the GPU driver, analog/onboard output is still silent, the
# motherboard's audio codec needs its vendor driver (Realtek/etc.) — this build
# fetches GPU drivers only, and with Windows Update disabled that codec driver
# won't arrive on its own; install it from the board maker's site.
Write-Log "=== Audio services (safety net) ==="
foreach ($svc in @("RpcSs", "AudioEndpointBuilder", "Audiosrv")) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s) {
        Set-Service -Name $svc -StartupType Automatic -ErrorAction SilentlyContinue
        if ($s.Status -ne "Running") { Start-Service -Name $svc -ErrorAction SilentlyContinue }
        Write-Log "  Confirmed $svc = Automatic (started)."
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# 5. STEAM — install + Big Picture autostart
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Steam ==="
$steamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
if (-not (Test-Path $steamExe)) {
    if ($script:WingetExe) { Install-WingetApp -Id "Valve.Steam" -Name "Steam" | Out-Null }
    if (-not (Test-Path $steamExe)) {
        if ($script:HaveNetwork) {
            Write-Log "  winget didn't land Steam — downloading the official Steam installer..."
            $installerPath = Join-Path $env:TEMP "SteamSetup.exe"
            try {
                Get-File -Uri "https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe" -OutFile $installerPath
                Start-Process -FilePath $installerPath -ArgumentList "/S" -Wait
            } catch {
                Write-Log "  Steam direct download failed (non-fatal): $_" "Yellow"
            }
        } else {
            Write-Log "  No network — cannot install Steam now." "Red"
        }
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

        # A tiny .cmd wrapper launches the (hidden) launcher — used by the
        # "Game Mode" desktop shortcut for manual re-entry (and by the Startup
        # shortcut only if the scheduled task below can't be registered).
        $EnterGameModeScript = Join-Path $GameModeDir "Enter-GameMode.cmd"
        @"
@echo off
start "" powershell.exe -NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$LauncherScript"
"@ | Set-Content -Path $EnterGameModeScript -Encoding ASCII

        # ── FAST LOGIN LAUNCH — an AtLogOn scheduled task, not a Startup shortcut ──
        # The user's ask: every boot AFTER the first should reach Steam as fast as
        # possible. A logon TASK fires the launcher the instant the session
        # starts — earlier than the shell gets around to processing the Startup
        # folder — so Steam begins loading in parallel with the desktop painting
        # and Big Picture is up sooner. It runs in the interactive session
        # (LogonType Interactive) so the splash + Big Picture have a desktop; no
        # elevation is needed (Steam/the splash don't require it). Falls back to a
        # Startup-folder shortcut if the task can't be registered, so autostart
        # never silently disappears.
        $StartupDir = Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\Startup"
        New-Item -ItemType Directory -Path $StartupDir -Force -ErrorAction SilentlyContinue | Out-Null
        $StartupLnk = Join-Path $StartupDir "Game Mode.lnk"
        $taskUser = "$env:USERDOMAIN\$env:USERNAME"
        $taskOk = $false
        try {
            $taskAction   = New-ScheduledTaskAction -Execute "powershell.exe" `
                -Argument "-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$LauncherScript`""
            $taskTrigger  = New-ScheduledTaskTrigger -AtLogOn -User $taskUser
            $taskPrincipal= New-ScheduledTaskPrincipal -UserId $taskUser -LogonType Interactive -RunLevel Limited
            $taskSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
            Register-ScheduledTask -TaskName "GameMode-Login" -Action $taskAction -Trigger $taskTrigger `
                -Principal $taskPrincipal -Settings $taskSettings -Force -ErrorAction Stop | Out-Null
            $taskOk = $true
            # Task owns the launch now — drop any legacy Startup shortcut so Steam
            # isn't launched twice (double splash) on machines upgraded from an
            # older build.
            Remove-Item $StartupLnk -Force -ErrorAction SilentlyContinue
            Write-Log "  Registered AtLogOn task 'GameMode-Login' for fast Big Picture launch on every login."
        } catch {
            Write-Log "  Could not register the logon task ($_) — falling back to a Startup-folder shortcut." "Yellow"
        }

        # Shortcuts: the desktop one is always created (manual re-entry); the
        # Startup one only as the task's fallback.
        $shell = New-Object -ComObject WScript.Shell
        $lnkTargets = @(@{ Path = Join-Path (Join-Path $env:PUBLIC "Desktop") "Game Mode.lnk"; Desc = "Return to Game Mode (Steam Big Picture)" })
        if (-not $taskOk) { $lnkTargets += @{ Path = $StartupLnk; Desc = "Launch Steam Big Picture at login" } }
        foreach ($lnkTarget in $lnkTargets) {
            $shortcut = $shell.CreateShortcut($lnkTarget.Path)
            $shortcut.TargetPath = $EnterGameModeScript
            $shortcut.WorkingDirectory = Split-Path $steamExe
            $shortcut.IconLocation = $steamExe
            $shortcut.WindowStyle = 7   # minimized — the .cmd window shouldn't flash
            $shortcut.Description = $lnkTarget.Desc
            $shortcut.Save()
        }
        Write-Log "  Set up Big Picture autostart + 'Game Mode' desktop shortcut for re-entry. explorer.exe remains the shell."
    } catch {
        Write-Log "  Failed to set up Game Mode autostart (non-fatal — explorer.exe is the shell, launch Steam manually): $_" "Red"
    }
} else {
    Write-Log "  Skipping Game Mode autostart — Steam was not confirmed installed." "Yellow"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5b-0. WEB BROWSER (Helium) — GUARANTEED install (winget + direct fallback)
# ═══════════════════════════════════════════════════════════════════════════
# Edge is removed OFFLINE in slim-image.ps1, so Helium is the machine's ONLY
# browser — it has to actually end up installed, not merely attempted. Unlike
# the other extra apps (best-effort winget in 5b), this tries winget first and
# then FALLS BACK to Helium's official installer from its GitHub releases —
# resolved via the GitHub API so the download link never goes stale — run
# silently (/S; it's an NSIS installer). Set as the default browser in 5c.
# Still non-fatal to first boot, but logged loudly if no browser could be had.
Write-Log "=== Web browser (Helium) ==="
function Test-HeliumInstalled {
    # Either signal means we have a working browser: the StartMenuInternet
    # registration Helium creates, or its executable on disk.
    foreach ($root in @("HKLM:\SOFTWARE\Clients\StartMenuInternet", "HKCU:\SOFTWARE\Clients\StartMenuInternet")) {
        if (Get-ChildItem $root -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like "*Helium*" }) { return $true }
    }
    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Helium\helium.exe",
        "$env:LOCALAPPDATA\Helium\Application\helium.exe",
        "$env:ProgramFiles\Helium\helium.exe",
        "${env:ProgramFiles(x86)}\Helium\helium.exe"
    )) { if (Test-Path $p) { return $true } }
    return $false
}
if ($script:WingetExe) {
    Install-WingetApp -Id "ImputNet.Helium" -Name "Helium browser" | Out-Null
} else {
    Write-Log "  winget unavailable — going straight to Helium's GitHub installer." "Yellow"
}
if (-not (Test-HeliumInstalled)) {
    if ($script:HaveNetwork) {
        Write-Log "  Helium not present after winget — falling back to the official GitHub installer." "Yellow"
        try {
            $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/imputnet/helium-windows/releases/latest" -Headers @{ "User-Agent" = "win11-minimal-gaming" } -UseBasicParsing -TimeoutSec 60
            $asset = $rel.assets | Where-Object { $_.name -match "x64-installer\.exe$" } | Select-Object -First 1
            if (-not $asset) { $asset = $rel.assets | Where-Object { $_.name -match "installer\.exe$" } | Select-Object -First 1 }
            if (-not $asset) { throw "No Windows installer asset in the latest Helium release." }
            $heliumExe = Join-Path $env:TEMP $asset.name
            Write-Log "    Downloading $($asset.browser_download_url) ..."
            Get-File -Uri $asset.browser_download_url -OutFile $heliumExe -TimeoutSec 600
            Write-Log "    Installing Helium silently (/S)..."
            Start-Process -FilePath $heliumExe -ArgumentList "/S" -Wait
        } catch {
            Write-Log "    Helium direct-download install failed: $_" "Red"
        }
    } else {
        Write-Log "  No network — cannot install a browser now." "Red"
    }
}
if (Test-HeliumInstalled) {
    Write-Log "  Helium browser is installed."
} else {
    Write-Log "  WARNING: no browser could be installed (Edge is removed) — install one manually from https://helium.computer/ once online." "Red"
}

# ═══════════════════════════════════════════════════════════════════════════
# 5b. EXTRA APPS — browsers, file manager, AI CLIs (all via winget)
# ═══════════════════════════════════════════════════════════════════════════
# All installed from winget's main community source. winget is deliberately
# KEPT in the image for this (slim-image.ps1 no longer removes
# Microsoft.DesktopAppInstaller). Everything here is best-effort/non-fatal:
# a failed app install just logs and continues — it never aborts first boot.
#   - Google Chrome            Google.Chrome
#   (Helium, the default browser, is installed separately in 5b-0 with a
#    direct-download fallback — it's the machine's only browser, so it can't
#    be left to this best-effort loop.)
#   - Files (file manager)     FilesCommunity.Files  (set as default — see 5c)
#   - Git for Windows          Git.Git           (REQUIRED by Claude Code — it
#                                                  shells out to Git Bash)
#   - Claude Code (AI CLI)     Anthropic.ClaudeCode
#   - opencode (AI CLI)        SST.opencode
Write-Log "=== Extra apps (winget) ==="
if (-not $script:WingetExe) {
    Write-Log "  winget could not be resolved — skipping the extra winget apps (Chrome, Files, Git, Claude Code, opencode). Run them later once winget works: winget install --id <Id> -e" "Red"
} elseif (-not $script:HaveNetwork) {
    Write-Log "  No network — skipping the extra winget apps." "Red"
} else {
    Install-WingetApp -Id "Google.Chrome"         -Name "Google Chrome"           | Out-Null
    Install-WingetApp -Id "FilesCommunity.Files"  -Name "Files (file manager)"     | Out-Null
    Install-WingetApp -Id "Git.Git"               -Name "Git for Windows (Claude Code prerequisite)" | Out-Null
    Install-WingetApp -Id "Anthropic.ClaudeCode"  -Name "Claude Code"             | Out-Null
    Install-WingetApp -Id "SST.opencode"          -Name "opencode"               | Out-Null
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
    # The Files "stable" channel installs an app-execution alias named
    # files-stable.exe (preview → files-preview.exe); there is no bare files.exe.
    # This alias path is stable across app updates, unlike the versioned
    # C:\Program Files\WindowsApps\Files_<ver>__... folder, so target the alias.
    $appsDir = "$env:LOCALAPPDATA\Microsoft\WindowsApps"
    $filesAlias = Get-ChildItem $appsDir -Filter "files-stable.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $filesAlias) {
        $filesAlias = Get-ChildItem $appsDir -Filter "*files*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $filesAlias) {
        Write-Log "  Files launcher alias not found in WindowsApps — skipping default-file-manager step." "Yellow"
    } else {
        # %1 = the folder/drive path for Directory/Drive/Folder;
        # %V is the same for the folder-window background verb.
        # Directory  = a filesystem folder,  Drive = a volume root,
        # Folder     = the base namespace class both derive from.
        foreach ($map in @(
            @{ Cls = "Directory";            Arg = "%1" },
            @{ Cls = "Directory\Background"; Arg = "%V" },
            @{ Cls = "Drive";                Arg = "%1" },
            @{ Cls = "Folder";               Arg = "%1" }
        )) {
            $cmdKey = "HKCU:\Software\Classes\$($map.Cls)\shell\open\command"
            New-Item -Path $cmdKey -Force -ErrorAction SilentlyContinue | Out-Null
            Set-ItemProperty -Path $cmdKey -Name "(default)" -Value "`"$($filesAlias.FullName)`" `"$($map.Arg)`"" -ErrorAction SilentlyContinue
            # The base image ships DelegateExecute={11dbb47c-...} on the HKLM
            # open\command verb, which takes precedence over any command string
            # and routes folder opens back into Explorer. Merely removing the
            # (absent) HKCU value does nothing — the HKLM GUID still wins. We
            # must SET an EMPTY DelegateExecute in HKCU so it shadows the HKLM
            # GUID, letting our command string run instead.
            Set-ItemProperty -Path $cmdKey -Name "DelegateExecute" -Value "" -ErrorAction SilentlyContinue
        }
        Write-Log "  Set Files as the default folder handler (Directory + Drive + Folder open command)."
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
# 7. FIRST-BOOT LAUNCH — end first boot IN Big Picture, then drop the splash
# ═══════════════════════════════════════════════════════════════════════════
# The Startup-folder "Game Mode" shortcut set up in step 5a only fires from the
# NEXT login onward — it doesn't exist yet when Windows processes Startup for
# this very first login. So first boot would otherwise end on the bare desktop.
# Launch Big Picture here too, hold the loader until Steam's UI has painted,
# then signal the loader to close — so the machine goes straight into Steam on
# the first boot exactly like every boot after it.
Write-Log "=== Launching Steam Big Picture ==="
try {
    $steamExeFinal = "${env:ProgramFiles(x86)}\Steam\steam.exe"
    if (Test-Path $steamExeFinal) {
        # Cold start goes straight to Big Picture via -bigpicture; if the Steam
        # installer already left a client running, switch it with the URL instead
        # (-bigpicture would only focus the existing window).
        if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
            Start-Process -FilePath $steamExeFinal -ArgumentList "-start","steam://open/bigpicture" -ErrorAction SilentlyContinue
        } else {
            Start-Process -FilePath $steamExeFinal -ArgumentList "-bigpicture" -ErrorAction SilentlyContinue
        }
        Write-Log "  Launched Big Picture; holding the loader until steamwebhelper appears."
        $waited = 0
        while ($waited -lt 90 -and -not (Get-Process -Name steamwebhelper -ErrorAction SilentlyContinue)) {
            Start-Sleep -Seconds 1; $waited++
        }
        Start-Sleep -Seconds 4   # let Big Picture actually paint before we uncover it
    } else {
        Write-Log "  Steam not confirmed installed — first boot will end on the desktop; Big Picture starts on next login." "Yellow"
    }
} catch {
    Write-Log "  Big Picture launch failed (non-fatal, desktop remains): $_" "Yellow"
}

# Tell the fullscreen loader to close (reveals Big Picture, or the desktop).
Set-BootStatus "__DONE__"
Start-Sleep -Milliseconds 750
if ($loaderProc) {
    try {
        if (-not $loaderProc.HasExited) { Start-Sleep -Seconds 2 }
        if (-not $loaderProc.HasExited) { $loaderProc.CloseMainWindow() | Out-Null }
        if (-not $loaderProc.HasExited) { Stop-Process -Id $loaderProc.Id -Force -ErrorAction SilentlyContinue }
    } catch {}
}

# ═══════════════════════════════════════════════════════════════════════════
Write-Log "==== first-boot-tweaks.ps1 finished ===="
Write-Log "Manual restore reminders (not scripted, no -Undo mode in this project):" "Cyan"
Write-Log "  - Edge: https://www.microsoft.com/edge" "Cyan"
Write-Log "  - OneDrive: https://www.microsoft.com/microsoft-365/onedrive/download" "Cyan"
Write-Log "  - Windows Update: Settings > Windows Update, or remove the NoAutoUpdate policy value above and re-enable wuauserv/UsoSvc." "Cyan"
Write-Log "  - Driver updates: run C:\ProgramData\DriverUpdate\Update-Drivers.ps1 (elevated) any time; the weekly 'MinimalGaming-DriverCheck' task offers them automatically. Remove that task to stop the weekly check." "Cyan"
Write-Log "  - Autologon: remove AutoAdminLogon/DefaultUserName/DefaultDomainName from $WinlogonPath" "Cyan"
Write-Log "Log saved to $LogFile"
