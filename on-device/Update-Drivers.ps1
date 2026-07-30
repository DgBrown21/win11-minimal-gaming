<#
.SYNOPSIS
    Driver-only updater for the minimal gaming image, safe to run while
    Windows Update is otherwise disabled.

.DESCRIPTION
    first-boot-tweaks.ps1 turns Windows Update OFF hard (wuauserv + UsoSvc
    disabled, the WindowsUpdate / UpdateOrchestrator task trees disabled,
    NoAutoUpdate=1). That also kills the normal path Windows uses to keep
    DEVICE DRIVERS current — so on this build only the GPU driver (fetched
    from the vendor at first boot) ever updates; chipset, NIC, audio codec,
    Bluetooth, etc. would stay frozen at whatever shipped in the image.

    This script restores JUST the driver path without re-enabling Windows
    Update for the OS. It drives the Windows Update Agent COM API with a
    search filter of "Type='Driver'", so feature updates and cumulative/
    quality updates are never fetched or offered — only hardware drivers.
    To do that it briefly flips wuauserv to Manual and starts it, does its
    work, then puts wuauserv back exactly how it found it (Disabled on this
    image). NoAutoUpdate stays set the whole time; it only blocks AUTOMATIC
    updating, not this explicit, driver-scoped, on-demand call.

    MODES (mutually exclusive; default is -Interactive):
      -Auto         Search + download + install ALL offered drivers with no
                    prompts. Used once at first boot to pick up the non-GPU
                    drivers, and usable any time for a hands-off refresh.
      -Interactive  List the offered drivers, ask Y/N, install if approved.
                    This is the "gives you the option to install" UI.
      -Notify       Silent scan (no window). If drivers ARE offered, show a
                    toast and open the -Interactive window. If nothing is
                    offered, exit silently. This is what the weekly task runs.

    Every failure is non-fatal and logged to
    C:\ProgramData\DriverUpdate\driver-update.log.

.NOTES
    Must run elevated (the COM installer requires admin). The weekly task
    registered by first-boot-tweaks.ps1 runs it with RunLevel Highest.
#>
[CmdletBinding(DefaultParameterSetName = "Interactive")]
param(
    [Parameter(ParameterSetName = "Auto")]        [switch]$Auto,
    [Parameter(ParameterSetName = "Interactive")] [switch]$Interactive,
    [Parameter(ParameterSetName = "Notify")]      [switch]$Notify
)

$ErrorActionPreference = "Stop"

# ── Logging ────────────────────────────────────────────────────────────────
$LogDir  = Join-Path $env:ProgramData "DriverUpdate"
$LogFile = Join-Path $LogDir "driver-update.log"
New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue | Out-Null
function Write-Log {
    param([string]$Message, [string]$Color = "Gray")
    $line = "{0}  {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    try { Add-Content -Path $LogFile -Value $line -ErrorAction SilentlyContinue } catch {}
    Write-Host $Message -ForegroundColor $Color
}

# ── Must be elevated ───────────────────────────────────────────────────────
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "Not elevated — the Windows Update COM installer needs admin. Re-run as Administrator." "Red"
    exit 1
}

$Mode = $PSCmdlet.ParameterSetName   # Auto | Interactive | Notify
$SelfPath = $PSCommandPath

# ── Best-effort native toast (no BurntToast dependency) ────────────────────
# Uses the built-in WinRT toast APIs. On a minimal image with no registered
# AppUserModelID the toast may silently not appear — that's fine, it's a
# bonus; the interactive window is the guaranteed notification path.
function Show-Toast {
    param([string]$Title, [string]$Body)
    try {
        [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $xml  = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
        $texts = $xml.GetElementsByTagName("text")
        $texts.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $texts.Item(1).AppendChild($xml.CreateTextNode($Body))  | Out-Null
        $toast    = [Windows.UI.Notifications.ToastNotification]::new($xml)
        # Use a stable, always-present AppID so Action Center accepts the toast.
        $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe")
        $notifier.Show($toast)
    } catch {
        # Toast is best-effort; ignore any failure.
    }
}

# ── Temporarily allow the WU agent to run, drivers only ────────────────────
# Returns the original StartMode so it can be restored verbatim.
function Enable-WuAgent {
    $orig = "Disabled"
    try {
        $svc = Get-CimInstance Win32_Service -Filter "Name='wuauserv'" -ErrorAction SilentlyContinue
        if ($svc) { $orig = $svc.StartMode }   # Auto | Manual | Disabled
    } catch {}
    try {
        Set-Service -Name wuauserv -StartupType Manual -ErrorAction SilentlyContinue
        Start-Service -Name wuauserv -ErrorAction SilentlyContinue
        Write-Log "  wuauserv temporarily Manual+started for the driver query (was $orig)."
    } catch {
        Write-Log "  Could not start wuauserv: $_" "Yellow"
    }
    return $orig
}
function Restore-WuAgent {
    param([string]$Orig)
    try { Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue } catch {}
    try {
        if ($Orig -in @("Disabled", "Manual", "Auto")) {
            $map = @{ "Auto" = "Automatic"; "Manual" = "Manual"; "Disabled" = "Disabled" }
            Set-Service -Name wuauserv -StartupType $map[$Orig] -ErrorAction SilentlyContinue
            Write-Log "  wuauserv restored to $($map[$Orig])."
        }
    } catch {
        Write-Log "  Could not restore wuauserv startup type: $_" "Yellow"
    }
}

# ── Search the WU driver catalog (drivers only) ────────────────────────────
# Returns the raw ISearchResult; the caller inspects .Updates.
function Search-Drivers {
    Write-Log "  Searching the Windows Update driver catalog (Type='Driver' only)..."
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    # "IsInstalled=0 and Type='Driver' and IsHidden=0" restricts the result to
    # not-yet-installed hardware drivers — feature/quality updates are excluded
    # by construction, so this never pulls a Windows OS update.
    $result = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    return @{ Session = $session; Result = $result }
}

# ── Download + install a chosen set of updates ─────────────────────────────
function Install-DriverSet {
    param($Session, $Updates)   # $Updates = array of IUpdate

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) {
        try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
        $coll.Add($u) | Out-Null
    }

    Write-Log "  Downloading $($coll.Count) driver package(s)..."
    $downloader = $Session.CreateUpdateDownloader()
    $downloader.Updates = $coll
    $dl = $downloader.Download()
    Write-Log "    Download result code: $($dl.ResultCode) (2 = Succeeded)."

    Write-Log "  Installing..."
    $installer = $Session.CreateUpdateInstaller()
    $installer.Updates = $coll
    $ir = $installer.Install()
    Write-Log "    Install result code: $($ir.ResultCode) (2 = Succeeded)." $(if ($ir.ResultCode -eq 2) { "Green" } else { "Yellow" })
    return $ir
}

# ── Relaunch this script in a visible, elevated window ─────────────────────
function Start-InteractiveWindow {
    Write-Log "  Opening the interactive install window..."
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$SelfPath`"", "-Interactive") `
        -Verb RunAs -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "==== Update-Drivers.ps1 ($Mode) starting ===="

$origStart = Enable-WuAgent
$exitCode  = 0
try {
    $search  = Search-Drivers
    $updates = @($search.Result.Updates)
    Write-Log "  $($updates.Count) driver update(s) offered."

    if ($updates.Count -eq 0) {
        Write-Log "  No driver updates available. Nothing to do." "Green"
    }
    elseif ($Mode -eq "Notify") {
        # Weekly task path: don't install here. Notify + hand off to a visible
        # window so the user gets the choice.
        $names = ($updates | ForEach-Object { $_.Title }) -join "; "
        Write-Log "  Drivers offered: $names"
        Show-Toast -Title "$($updates.Count) driver update(s) available" `
                   -Body  "Minimal Gaming found new hardware drivers. A window will open to let you install them."
        Restore-WuAgent -Orig $origStart   # let the child re-enable it itself
        Start-InteractiveWindow
        Write-Log "==== Update-Drivers.ps1 (Notify) finished — handed off to interactive window ===="
        exit 0
    }
    elseif ($Mode -eq "Auto") {
        foreach ($u in $updates) { Write-Log "    - $($u.Title)" }
        $ir = Install-DriverSet -Session $search.Session -Updates $updates
        if ($ir.RebootRequired) { Write-Log "  A reboot is required to finish applying one or more drivers." "Yellow" }
    }
    else {
        # Interactive
        Write-Host ""
        Write-Host "The following driver updates are available:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $updates.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $updates[$i].Title)
        }
        Write-Host ""
        $answer = Read-Host "Install these driver updates now? [Y]es / [N]o"
        if ($answer -match '^(y|yes)$') {
            $ir = Install-DriverSet -Session $search.Session -Updates $updates
            if ($ir.RebootRequired) {
                Write-Host ""
                Write-Host "A reboot is required to finish applying one or more drivers." -ForegroundColor Yellow
                $rb = Read-Host "Reboot now? [Y]es / [N]o"
                if ($rb -match '^(y|yes)$') { Restart-Computer -Force }
            } else {
                Write-Host "Done." -ForegroundColor Green
            }
            Write-Host ""
            Write-Host "Press Enter to close..." -ForegroundColor DarkGray
            [void](Read-Host)
        } else {
            Write-Log "  User declined. No drivers installed."
        }
    }
}
catch {
    Write-Log "  Driver update run failed (non-fatal): $_" "Red"
    $exitCode = 1
}
finally {
    Restore-WuAgent -Orig $origStart
}

Write-Log "==== Update-Drivers.ps1 ($Mode) finished ===="
exit $exitCode
