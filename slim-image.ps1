<#
.SYNOPSIS
    Offline DISM servicing: strips install.wim down to a single gaming-lean
    Windows 11 Pro edition and recompresses it as install.esd.

.DESCRIPTION
    This is the core size-reduction step of the Win11-Minimal-DB build,
    called by build-windows.ps1 in between "extract ISO" and "rebuild with
    oscdimg". Everything here operates OFFLINE on the image file — nothing
    in this script ever touches the machine it runs on, only the extracted
    install media in $ExtractDir\sources\install.wim.

    Microsoft Edge IS removed here, offline, comprehensively: Program Files
    folders (Edge / EdgeCore / EdgeUpdate), SystemApps (Microsoft.MicrosoftEdge*),
    any Edge-related provisioned Appx packages, SOFTWARE hive entries (uninstall
    entries, Image File Execution Options, Active Setup, protocol associations,
    MicrosoftEdge key), and SYSTEM hive services (edgeupdate/edgeupdatem) — all
    directly out of the mounted image, plus EdgeUpdate reinstall blocked in the
    offline registry (STEP 6c). This replaces the old plan of running Edge's
    own `setup.exe --uninstall` at first boot — that DISM *package*-removal /
    runtime-uninstaller path is what's unsupported and unreliable (Microsoft
    blocks --force-uninstall outside the EEA and it leaves EdgeCore/EdgeUpdate
    behind), which is why Edge kept surviving. WebView2
    (Program Files\Microsoft\EdgeWebView) is deliberately KEPT — unrelated apps
    depend on it.

    What this does NOT do: remove OneDrive (a per-user Win32 install whose
    official uninstaller is more complete than offline folder deletion) and
    does not touch Windows Update/Defender service state (that's live
    service/scheduled-task state, not image content). Those are handled
    instead by first-boot-tweaks.ps1 at first login on the installed machine.

    Order matters and is NOT safe to reshuffle:
      1. Resolve the Windows 11 Pro index by name (never by hardcoded
         number — the index number for Pro is not stable across builds).
      2. Export just that one index into a fresh WIM — drops every other
         edition's exclusive resources before anything else runs, so all
         later steps only ever service one edition instead of repeating
         work across 6-8 of them.
      3. Mount, remove Appx/Capabilities/Features, bake in NetFx3.
      4. /ResetBase component cleanup — this is what makes steps above
         actually shrink the image, by discarding WinSxS's superseded-
         version backup copies for everything just removed. TRADE-OFF:
         after this, the installed machine's Windows Update can no longer
         *uninstall* any currently-installed update/component (roll back
         to "None"). Normal, accepted trade-off for a freshly-imaged
         single-purpose build — not a concern here.
      5. Commit + unmount, then recompress WIM -> ESD (LZMS) as the final,
         usually single-biggest, size win.

.PARAMETER ExtractDir
    Path to the extracted Windows install media (the folder containing
    "sources", "boot", "efi" — same folder oscdimg will package). Expects
    $ExtractDir\sources\install.wim to exist.

.EXAMPLE
    .\slim-image.ps1 -ExtractDir "C:\Users\DeeBee\Win11-Minimal-DB\build\extracted"
#>
param(
    [Parameter(Mandatory)][string]$ExtractDir
)

$ErrorActionPreference = "Stop"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "This script must be run as Administrator (Mount-WindowsImage/DISM require it). Re-launch an elevated PowerShell and try again." -ForegroundColor Red
    exit 1
}

function Write-Log {
    param([string]$Message, [string]$Color = "White")
    Write-Host ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -ForegroundColor $Color
}

function Get-SizeGB {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    [math]::Round((Get-Item $Path).Length / 1GB, 2)
}

$WimPath  = Join-Path $ExtractDir "sources\install.wim"
$EsdPath  = Join-Path $ExtractDir "sources\install.esd"
$MountDir = Join-Path (Split-Path -Parent $ExtractDir) "mount"
$SlimTemp = Join-Path (Split-Path -Parent $ExtractDir) "install-slim.wim"

if (-not (Test-Path $WimPath)) {
    throw "install.wim not found at $WimPath — run this after the ISO has been extracted, before oscdimg rebuild."
}

$sizeBefore = Get-SizeGB $WimPath
Write-Log "==== slim-image.ps1 starting — install.wim is currently ${sizeBefore}GB ===="

# ═══════════════════════════════════════════════════════════════════════════
# STEP 0 — pre-flight: clear any orphaned mount from a previous failed run
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Pre-flight: clearing any stale mount state ==="
New-Item -ItemType Directory -Path $MountDir -Force | Out-Null
Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $MountDir } | ForEach-Object {
    Write-Log "  Found a stale mount at $MountDir from a previous run — discarding it." "Yellow"
    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
}
& dism.exe /Cleanup-Mountpoints | Out-Null

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — resolve the Windows 11 Pro index by name
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Resolving the Windows 11 Pro index ==="
$images = Get-WindowsImage -ImagePath $WimPath
$proImage = @($images | Where-Object { $_.ImageName -eq "Windows 11 Pro" })
if ($proImage.Count -ne 1) {
    Write-Log "Could not uniquely resolve 'Windows 11 Pro' — indices found:" "Red"
    $images | Format-Table ImageIndex, ImageName | Out-String | Write-Host
    throw "Expected exactly one 'Windows 11 Pro' index, found $($proImage.Count). Inspect the list above — ImageName may have changed for this Windows build."
}
$proIndex = $proImage[0].ImageIndex
Write-Log "  Found 'Windows 11 Pro' at index $proIndex (of $($images.Count) total editions in this WIM)."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — export just that one index into a fresh WIM
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Exporting single-edition WIM (drops every other edition's exclusive resources) ==="
Remove-Item $SlimTemp -Force -ErrorAction SilentlyContinue
Export-WindowsImage -SourceImagePath $WimPath -SourceIndex $proIndex `
    -DestinationImagePath $SlimTemp -CompressionType Max | Out-Null
Remove-Item $WimPath -Force
Move-Item $SlimTemp $WimPath
Write-Log "  Single-edition export done — install.wim is now $(Get-SizeGB $WimPath)GB."

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — mount
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "=== Mounting install.wim (index 1 — the only index left after Step 2) ==="
Mount-WindowsImage -ImagePath $WimPath -Index 1 -Path $MountDir | Out-Null

try {
    # ═══════════════════════════════════════════════════════════════════════
    # STEP 4 — provisioned Appx removal
    # ═══════════════════════════════════════════════════════════════════════
    # Same list the sibling Win11-Install project's debloat-lockdown.ps1 uses
    # live, applied here offline instead. Deliberately KEPT (do not add):
    #   Microsoft.Xbox.TCUI, Microsoft.XboxIdentityProvider,
    #   Microsoft.XboxSpeechToTextOverlay — some games' Xbox-Live sign-in/
    #   crossplay/overlay depend on these even when launched via Steam;
    #   only ~27MB combined, not worth the regression risk on a gaming build.
    #   Microsoft.VCLibs*, Microsoft.NET.Native.*, Microsoft.UI.Xaml.*,
    #   Microsoft.WindowsAppRuntime.* — runtime dependencies other apps
    #   (Steam included) silently rely on.
    #   Microsoft.SecHealthUI — Defender's security-center UI; Defender
    #   must keep working per this project's requirements.
    #   Microsoft.Windows.CloudExperienceHost, Microsoft.AAD.BrokerPlugin,
    #   Microsoft.AccountsControl, Microsoft.LockApp,
    #   Microsoft.Windows.ShellExperienceHost,
    #   Microsoft.Windows.StartMenuExperienceHost — required for OOBE/
    #   logon/shell to function at all; removing any of these produces a
    #   non-bootable-to-desktop image.
    #
    #   REVERSED 2026-07-24: Calculator, Notepad, Paint, Photos, Camera,
    #   Snip & Sketch, Store, StorePurchaseApp, DesktopAppInstaller (winget),
    #   Outlook for Windows, Quick Assist, Cross Device, Bing Search are now
    #   REMOVED below (~320MB) — none are gaming-relevant. Removing
    #   DesktopAppInstaller/WindowsStore is safe here specifically because
    #   first-boot-tweaks.ps1's Steam install already falls back to a direct
    #   SteamSetup.exe download when `Get-Command winget` finds nothing —
    #   confirmed no other step in this project depends on winget/Store
    #   being present on the installed machine.
    Write-Log "=== Removing provisioned Appx packages ==="
    $AppsToRemove = @(
        "Microsoft.549981C3F5F10"              # Cortana
        "Clipchamp.Clipchamp"
        "Microsoft.3DBuilder"
        "Microsoft.BingFinance"
        "Microsoft.BingFoodAndDrink"
        "Microsoft.BingHealthAndFitness"
        "Microsoft.BingNews"
        "Microsoft.BingSports"
        "Microsoft.BingTranslator"
        "Microsoft.BingTravel"
        "Microsoft.BingWeather"
        "Microsoft.GetHelp"
        "Microsoft.Getstarted"
        "Microsoft.Messaging"
        "Microsoft.MicrosoftOfficeHub"
        "Microsoft.MicrosoftSolitaireCollection"
        "Microsoft.MicrosoftStickyNotes"
        "Microsoft.MixedReality.Portal"
        "Microsoft.NetworkSpeedTest"
        "Microsoft.News"
        "Microsoft.Office.OneNote"
        "Microsoft.OneConnect"
        "Microsoft.People"
        "Microsoft.Print3D"
        "Microsoft.SkypeApp"
        "Microsoft.Wallet"
        "Microsoft.WindowsAlarms"
        "Microsoft.WindowsCommunicationsApps"   # Mail and Calendar
        "Microsoft.WindowsFeedbackHub"
        "Microsoft.WindowsMaps"
        "Microsoft.WindowsSoundRecorder"
        "Microsoft.XboxApp"                     # old Xbox Console Companion
        "Microsoft.GamingApp"                   # new Xbox app
        "Microsoft.XboxGameOverlay"
        "Microsoft.XboxGamingOverlay"
        "Microsoft.YourPhone"
        "Microsoft.ZuneMusic"
        "Microsoft.ZuneVideo"
        "MicrosoftTeams"
        "MSTeams"
        "Microsoft.Todos"
        "Microsoft.PowerAutomateDesktop"
        "Microsoft.Windows.DevHome"
        "MicrosoftCorporationII.MicrosoftFamily"
        "Microsoft.WidgetsPlatformRuntime"
        "MicrosoftWindows.Client.WebExperience"
        "Microsoft.Copilot"
        "Microsoft.Windows.Ai.Copilot"
        # Added 2026-07-24 — non-gaming Store apps, see REVERSED note above
        "Microsoft.WindowsCalculator"
        "Microsoft.WindowsNotepad"
        "Microsoft.Paint"
        "Microsoft.Windows.Photos"
        "Microsoft.WindowsCamera"
        "Microsoft.ScreenSketch"
        "Microsoft.WindowsStore"
        "Microsoft.StorePurchaseApp"
        "Microsoft.DesktopAppInstaller"
        "Microsoft.OutlookForWindows"
        "MicrosoftCorporationII.QuickAssist"
        "MicrosoftWindows.CrossDevice"
        "Microsoft.BingSearch"
        "Microsoft.MicrosoftEdgeDevToolsClient"
    )
    $provBefore = @(Get-ProvisionedAppxPackage -Path $MountDir).Count
    foreach ($app in $AppsToRemove) {
        Get-ProvisionedAppxPackage -Path $MountDir |
            Where-Object DisplayName -eq $app |
            ForEach-Object {
                try {
                    Remove-ProvisionedAppxPackage -Path $MountDir -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                    Write-Log "  Removed: $app"
                } catch {
                    Write-Log "  Could not remove $app (non-fatal, continuing): $_" "Yellow"
                }
            }
    }
    $provAfter = @(Get-ProvisionedAppxPackage -Path $MountDir).Count
    Write-Log "  Provisioned Appx count: $provBefore -> $provAfter"

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 5 — Windows Capabilities (language/font/legacy add-ons)
    # ═══════════════════════════════════════════════════════════════════════
    # Capability full names carry a version suffix that shifts between
    # builds (e.g. "Language.Fonts.Kore~~~und-KORE~0.0.1.0") — always
    # resolve via wildcard match against the live image, never hardcode
    # the full versioned string.
    # Deliberately KEPT: OpenSSH.Client (tiny, useful for diagnostics),
    # Print.Management.Console, and en-GB's own active-language
    # components (Language.OCR/Speech/TextToSpeech/Handwriting for en-GB
    # itself — these are the language actually in use, not extras).
    Write-Log "=== Removing Windows Capabilities ==="
    $CapabilitiesToRemove = @(
        "App.StepsRecorder"
        "App.Support.QuickAssist"
        "Browser.InternetExplorer"
        "Hello.Face"
        "MathRecognizer"
        "Media.WindowsMediaPlayer"
        "Microsoft.Windows.WordPad"
        "Print.Fax.Scan"
        "VBSCRIPT"
        "RIP.Listener"
        "Language.Fonts.Arab"
        "Language.Fonts.Hebr"
        "Language.Fonts.Jpan"
        "Language.Fonts.Kore"
        "Language.Fonts.Hans"
        "Language.Fonts.Hant"
        "Language.Fonts.Thai"
        "Language.Fonts.Tibt"
        "Language.Fonts.PanEuropeanSupplementalFonts"
        "Language.Fonts.EastAsianSupplementalFonts"
        "Language.Fonts.MEASupplementalFonts"
        "Language.Fonts.SEAsianSupplementalFonts"
        "Language.Fonts.CentralAsianSupplementalFonts"
    )
    $capBefore = @(Get-WindowsCapability -Path $MountDir | Where-Object State -eq "Installed").Count
    foreach ($cap in $CapabilitiesToRemove) {
        Get-WindowsCapability -Path $MountDir -Name "$cap*" |
            Where-Object State -eq "Installed" |
            ForEach-Object {
                try {
                    Remove-WindowsCapability -Path $MountDir -Name $_.Name -ErrorAction Stop | Out-Null
                    Write-Log "  Removed: $($_.Name)"
                } catch {
                    Write-Log "  Could not remove $($_.Name) (non-fatal, continuing): $_" "Yellow"
                }
            }
    }
    $capAfter = @(Get-WindowsCapability -Path $MountDir | Where-Object State -eq "Installed").Count
    Write-Log "  Installed capability count: $capBefore -> $capAfter"

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 6 — disable Optional Features, bake in NetFx3
    # ═══════════════════════════════════════════════════════════════════════
    # Deliberately KEPT: LegacyComponents (DirectPlay) — near-zero size
    # cost, and older multiplayer titles can still depend on it. This
    # project's whole purpose is gaming, so keeping it is the safer
    # default.
    Write-Log "=== Disabling unneeded Optional Features ==="
    # -ErrorAction SilentlyContinue does NOT reliably suppress DISM errors —
    # some Microsoft.Dism cmdlet failures surface as terminating COM
    # exceptions that bypass PowerShell's normal error-action handling
    # (learned the hard way: "FaxServicesClientPackage is unknown" aborted
    # a whole run despite -ErrorAction SilentlyContinue on that line). Every
    # DISM call in this script that iterates a list must be wrapped in
    # try/catch, not just -ErrorAction, or one bad/renamed feature name
    # kills hours of prior work.
    $FeaturesToDisable = @(
        "WorkFolders-Client"
        "Printing-XPSServices-Features"
        "Printing-Foundation-Features"
        "Printing-Foundation-InternetPrinting-Client"
        "TelnetClient"
        "TFTP"
        "SimpleTCP"
        "Windows-Defender-ApplicationGuard"     # distinct from core Defender — safe, doesn't touch WinDefend/WdNisSvc
        "Containers-DisposableClientVM"          # Windows Sandbox
        "SMB1Protocol"
        "SMB1Protocol-Client"
        "SMB1Protocol-Server"
    )
    $availableFeatures = @((Get-WindowsOptionalFeature -Path $MountDir).FeatureName)
    foreach ($f in $FeaturesToDisable) {
        if ($availableFeatures -notcontains $f) {
            Write-Log "  Skipped (not present on this build): $f" "Yellow"
            continue
        }
        try {
            Disable-WindowsOptionalFeature -Path $MountDir -FeatureName $f -Remove -ErrorAction Stop | Out-Null
            Write-Log "  Disabled: $f"
        } catch {
            Write-Log "  Could not disable $f (non-fatal, continuing): $_" "Yellow"
        }
    }

    # Several older game installers, mod tools, and Unity-based titles
    # still require .NET Framework 3.5. Its normal fallback when missing
    # is a silent on-demand Windows Update fetch — which will fail once
    # WU is aggressively disabled by first-boot-tweaks.ps1 on the
    # installed machine. Baking it in offline here avoids that entirely.
    Write-Log "=== Enabling .NET Framework 3.5 (baked in offline — WU won't be available to fetch it later) ==="
    # The sxs payload lives on the INSTALL MEDIA (ExtractDir\sources\sxs),
    # not inside the WIM being serviced — $MountDir is the offline OS
    # image's own C:\, which has no sources\sxs of its own. Pointing
    # -Source at $MountDir\sources\sxs (the original bug here) always
    # fails with "source files could not be found".
    $sxsSource = Join-Path $ExtractDir "sources\sxs"
    try {
        Enable-WindowsOptionalFeature -Path $MountDir -FeatureName "NetFx3" -All -Source $sxsSource -LimitAccess -ErrorAction Stop | Out-Null
        Write-Log "  NetFx3 enabled."
    } catch {
        Write-Log "  Could not enable NetFx3 (non-fatal, continuing — some older titles may need it fetched manually later): $_" "Yellow"
    }

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 6b — disable Content Delivery Manager "suggested apps"
    # ═══════════════════════════════════════════════════════════════════════
    # Removing an app's provisioned Appx package (above) only stops it from
    # being part of the image — it does NOT stop Windows 11 from re-pulling
    # a fresh copy of that same app (or unrelated ones like WhatsApp/
    # LinkedIn/Solitaire, which were never provisioned here in the first
    # place) as a "suggested"/"recommended" Start tile during OOBE/first
    # login. That's Content Delivery Manager, a separate mechanism from
    # Appx provisioning entirely. Confirmed via VM boot test 2026-07-24:
    # Get-AppxProvisionedPackage against the shipped image showed none of
    # Calculator/Notepad/Paint/Photos/Outlook/Store present, yet all of
    # them (plus WhatsApp/LinkedIn/Solitaire) appeared on the Start menu
    # after first login anyway. Baked in here (offline, before Windows
    # ever boots) rather than in first-boot-tweaks.ps1, so the policy is
    # already active before OOBE ever gets a chance to trigger the fetch.
    Write-Log "=== Disabling Content Delivery Manager suggested-apps ==="
    $softwareHive = Join-Path $MountDir "Windows\System32\config\SOFTWARE"
    $hiveKey = "HKLM\SLIM_OFFLINE_SOFTWARE"
    & reg load $hiveKey $softwareHive | Out-Null
    try {
        $cloudContentKey = "$hiveKey\Policies\Microsoft\Windows\CloudContent"
        & reg add $cloudContentKey /v DisableWindowsConsumerFeatures /t REG_DWORD /d 1 /f | Out-Null
        & reg add $cloudContentKey /v DisableConsumerAccountStateContent /t REG_DWORD /d 1 /f | Out-Null
        & reg add $cloudContentKey /v DisableCloudOptimizedContent /t REG_DWORD /d 1 /f | Out-Null
        & reg add $cloudContentKey /v DisableSoftLanding /t REG_DWORD /d 1 /f | Out-Null

        $cdmKey = "$hiveKey\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
        & reg add $cdmKey /v SilentInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v OemPreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v PreInstalledAppsEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v PreInstalledAppsEverEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v SubscribedContentEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v SubscribedContent-338388Enabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v SubscribedContent-338389Enabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v SubscribedContent-353698Enabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v RotatingLockScreenEnabled /t REG_DWORD /d 0 /f | Out-Null
        & reg add $cdmKey /v RotatingLockScreenOverlayEnabled /t REG_DWORD /d 0 /f | Out-Null
        Write-Log "  CloudContent/ContentDeliveryManager policy set."
    } finally {
        # Registry hives stay locked briefly after use; GC + short retries
        # avoid "reg unload" failing with the process-still-has-a-handle error.
        [gc]::Collect()
        [gc]::WaitForPendingFinalizers()
        $unloaded = $false
        for ($i = 0; $i -lt 5 -and -not $unloaded; $i++) {
            & reg unload $hiveKey 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $unloaded = $true } else { Start-Sleep -Seconds 2 }
        }
        if (-not $unloaded) {
            throw "Could not unload $hiveKey after servicing it — a handle is still open. Aborting before commit rather than risk an inconsistent image."
        }
    }

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 6c — Microsoft Edge — thorough offline removal
    # ═══════════════════════════════════════════════════════════════════════
    # Edge is a hybrid: a Win32 install (Program Files + services + scheduled
    # tasks) plus a provisioned Appx (MicrosoftEdgeDevToolsClient) and legacy
    # SystemApps folders. The old approach — relying on the runtime
    # `setup.exe --uninstall --force-uninstall` at first boot — was unreliable
    # because Microsoft blocks --force-uninstall outside the EEA and it leaves
    # EdgeCore/EdgeUpdate behind (EdgeCore is a fully working Edge). This is
    # why Edge kept surviving on earlier builds.
    #
    # This STEP handles every facet offline, before the image ever boots:
    #   A) Delete Program Files folders (Edge, EdgeCore, EdgeUpdate)
    #   B) Delete SystemApps\Microsoft.MicrosoftEdge* (legacy Edge UWP)
    #   C) Deprovision any Edge-related Appx packages
    #   D) Scrub the SOFTWARE hive (uninstall entries, active-setup, assocs,
    #      Image File Execution Options, MicrosoftEdge key)
    #   E) Scrub the SYSTEM hive (edgeupdate/edgeupdatem services)
    #   F) Block EdgeUpdate reinstall (DoNotUpdateToEdgeWithChromium etc.)
    #
    # WebView2 (Program Files (x86)\Microsoft\EdgeWebView) is deliberately
    # KEPT — unrelated apps depend on it.
    Write-Log "=== Removing Microsoft Edge (offline — folders, Appx, registry, services) ==="
    $adminGroup = (New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")).Translate([System.Security.Principal.NTAccount]).Value

    # ── A) Delete Program Files folders ──
    Write-Log "  Phase A — deleting Program Files folders..."
    foreach ($rel in @(
        "Program Files (x86)\Microsoft\Edge"
        "Program Files (x86)\Microsoft\EdgeCore"
        "Program Files (x86)\Microsoft\EdgeUpdate"
    )) {
        $full = Join-Path $MountDir $rel
        if (Test-Path $full) {
            & takeown /f "$full" /r /d y | Out-Null
            & icacls "$full" /grant "$($adminGroup):(F)" /t /c | Out-Null
            Remove-Item -Path $full -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "  Deleted: $rel"
        } else {
            Write-Log "  Not present (already gone): $rel" "Yellow"
        }
    }

    # ── B) Delete legacy SystemApps folders (from Edge-Appx.bat approach) ──
    Write-Log "  Phase B — removing legacy Edge SystemApps..."
    $sysAppsBase = Join-Path $MountDir "Windows\SystemApps"
    if (Test-Path $sysAppsBase) {
        Get-ChildItem -Path $sysAppsBase -Directory -Filter "Microsoft.MicrosoftEdge*" -ErrorAction SilentlyContinue | ForEach-Object {
            & takeown /f $_.FullName /r /d y 2>$null | Out-Null
            & icacls $_.FullName /grant "$($adminGroup):(F)" /t /c 2>$null | Out-Null
            Remove-Item -Path $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "  Deleted: $($_.Name)"
        }
    }

    # ── C) Deprovision any Edge-related Appx packages ──
    Write-Log "  Phase C — deprovisioning Edge Appx packages..."
    Get-ProvisionedAppxPackage -Path $MountDir -ErrorAction SilentlyContinue |
        Where-Object { $_.PackageName -like '*microsoftedge*' -or $_.PackageName -like '*Edge*' } |
        ForEach-Object {
            try {
                Remove-ProvisionedAppxPackage -Path $MountDir -PackageName $_.PackageName -ErrorAction Stop | Out-Null
                Write-Log "  Deprovisioned: $($_.PackageName)"
            } catch {
                Write-Log "  Could not deprovision $($_.PackageName) (non-fatal): $_" "Yellow"
            }
        }

    # ── D+E+F) Registry clean-up in SOFTWARE + SYSTEM hives ──
    Write-Log "  Phase D+E+F — registry cleanup (SOFTWARE + SYSTEM + reinstall block)..."
    $edgeHiveKey = "HKLM\SLIM_OFFLINE_EDGE"
    & reg load $edgeHiveKey $softwareHive | Out-Null
    $systemHive = Join-Path $MountDir "Windows\System32\config\SYSTEM"
    $systemHiveKey = "HKLM\SLIM_OFFLINE_SYSTEM"
    & reg load $systemHiveKey $systemHive | Out-Null
    try {
        # ── D) SOFTWARE hive ──
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\EdgeUpdate\Clients\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\EdgeUpdate\ClientState\{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\msedge.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ie_to_edge_stub.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MicrosoftEdgeUpdate.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\msedge.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\ie_to_edge_stub.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\WOW6432Node\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\MicrosoftEdgeUpdate.exe" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Microsoft\Active Setup\Installed Components\{9459C573-B17A-45AE-9F64-1857B5D58CEE}" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Microsoft\MicrosoftEdge" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Classes\microsoft-edge" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Classes\MSEdgeHTM" /f 2>$null | Out-Null
        & reg delete "$edgeHiveKey\Classes\MSEdgeHTML" /f 2>$null | Out-Null
        & reg add "$edgeHiveKey\WOW6432Node\Microsoft\EdgeUpdateDev" /v AllowUninstall /t REG_SZ /d "1" /f 2>$null | Out-Null

        # ── E) SYSTEM hive — disable EdgeUpdate services ──
        foreach ($ctrlSet in @("ControlSet001", "ControlSet002", "CurrentControlSet")) {
            foreach ($svc in @("edgeupdate", "edgeupdatem")) {
                & reg delete "$systemHiveKey\$ctrlSet\Services\$svc" /f 2>$null | Out-Null
            }
        }

        # ── F) Block EdgeUpdate reinstall ──
        foreach ($euRoot in @("$edgeHiveKey\Microsoft\EdgeUpdate", "$edgeHiveKey\WOW6432Node\Microsoft\EdgeUpdate")) {
            & reg add $euRoot /v DoNotUpdateToEdgeWithChromium /t REG_DWORD /d 1 /f | Out-Null
            & reg add $euRoot /v InstallDefault /t REG_DWORD /d 0 /f | Out-Null
            & reg add $euRoot /v "Install{56EB18F8-B008-4CBD-B6D2-8C97FE7E9062}" /t REG_DWORD /d 0 /f | Out-Null
        }
        Write-Log "  Edge fully removed from SOFTWARE + SYSTEM hives; reinstall blocked."
    } finally {
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        $euUnloaded = $false
        for ($i = 0; $i -lt 5 -and -not $euUnloaded; $i++) {
            & reg unload $edgeHiveKey 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $euUnloaded = $true } else { Start-Sleep -Seconds 2 }
        }
        if (-not $euUnloaded) {
            throw "Could not unload $edgeHiveKey after the Edge registry step — a handle is still open."
        }
        [gc]::Collect(); [gc]::WaitForPendingFinalizers()
        $sysUnloaded = $false
        for ($i = 0; $i -lt 5 -and -not $sysUnloaded; $i++) {
            & reg unload $systemHiveKey 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { $sysUnloaded = $true } else { Start-Sleep -Seconds 2 }
        }
        if (-not $sysUnloaded) {
            throw "Could not unload $systemHiveKey after the Edge registry step — a handle is still open."
        }
    }

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 7 — component-store cleanup (the step that makes removals count)
    # ═══════════════════════════════════════════════════════════════════════
    # /ResetBase discards WinSxS's superseded-version backup copies for
    # every package removed above. TRADE-OFF: after this, the installed
    # machine can no longer roll back an update/component to "None" via
    # Windows Update. Accepted trade-off for a freshly-imaged single-
    # purpose gaming build.
    Write-Log "=== Component-store cleanup (/ResetBase) — this is typically the slowest single step ==="
    Repair-WindowsImage -Path $MountDir -StartComponentCleanup -ResetBase | Out-Null
    Write-Log "  Component cleanup done."

    # ═══════════════════════════════════════════════════════════════════════
    # STEP 8 — sanity check, commit, unmount
    # ═══════════════════════════════════════════════════════════════════════
    Write-Log "=== Health check before commit ==="
    $health = Repair-WindowsImage -Path $MountDir -CheckHealth
    Write-Log "  ImageHealthState: $($health.ImageHealthState)"
    if ($health.ImageHealthState -ne "Healthy") {
        throw "Image health check reported '$($health.ImageHealthState)' after servicing — aborting before commit. Check the DISM log (C:\Windows\Logs\DISM\dism.log) for what went wrong."
    }

    Write-Log "=== Committing and unmounting ==="
    Dismount-WindowsImage -Path $MountDir -Save | Out-Null
    Write-Log "  Committed. install.wim is now $(Get-SizeGB $WimPath)GB."
}
catch {
    Write-Log "Servicing failed — discarding the mount rather than committing a possibly-broken image: $_" "Red"
    Dismount-WindowsImage -Path $MountDir -Discard -ErrorAction SilentlyContinue | Out-Null
    throw
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 9 — final compression pass: WIM -> ESD (LZMS)
# ═══════════════════════════════════════════════════════════════════════════
# The Export-WindowsImage cmdlet's -CompressionType only accepts
# None/Fast/Max — it cannot produce true LZMS/ESD compression, so this has
# to shell out to dism.exe directly. Usually the single biggest size win in
# the whole pipeline, and also usually the slowest single step (LZMS is
# CPU-bound solid compression — expect 15-40 minutes).
Write-Log "=== Final compression: WIM -> ESD (this is typically the slowest step — 15-40+ min) ==="
Remove-Item $EsdPath -Force -ErrorAction SilentlyContinue
& dism.exe /Export-Image /SourceImageFile:"$WimPath" /SourceIndex:1 /DestinationImageFile:"$EsdPath" /Compress:recovery
if ($LASTEXITCODE -ne 0) {
    throw "dism /Export-Image (WIM->ESD) failed with exit code $LASTEXITCODE — install.wim was left in place, ESD conversion did not complete."
}
Remove-Item $WimPath -Force
Write-Log "  ESD conversion done — Setup will find install.esd in place of install.wim (natively supported, same format Windows Update itself uses for feature updates)."

# ═══════════════════════════════════════════════════════════════════════════
Write-Log "==== slim-image.ps1 finished ===="
Write-Log ("  install.wim before: {0}GB" -f $sizeBefore)
Write-Log ("  install.esd after:  {0}GB" -f (Get-SizeGB $EsdPath))
Write-Log "  NOTE: this is only the boot/install image's contribution to final ISO size — boot.wim, drivers, and other sources\ files are unchanged and add on top of this."
