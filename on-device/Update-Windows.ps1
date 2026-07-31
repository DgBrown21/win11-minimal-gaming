<#
.SYNOPSIS
    On-demand Windows (OS) updater for the minimal gaming image, safe to run
    while Windows Update is otherwise disabled. SECURITY updates install
    straight away; other OS updates prompt the user to Install now or defer
    by 1 / 2 / 4 weeks or 1 year.

.DESCRIPTION
    first-boot-tweaks.ps1 turns Windows Update OFF hard (wuauserv + UsoSvc
    disabled, the WindowsUpdate / UpdateOrchestrator task trees disabled,
    NoAutoUpdate=1) so the OS never patches itself unattended on this build.
    Update-Drivers.ps1 already restores the driver path; this script is its
    OS-update counterpart. It drives the Windows Update Agent COM API with a
    search filter of "Type='Software'", so it sees the OS updates a normal
    machine would get from Windows Update, then SPLITS them:

      * SECURITY updates (anything with an MSRC severity, plus the "Security
        Updates" and Defender "Definition Updates" categories) install
        automatically, straight away, with no prompt. This covers the monthly
        cumulative security update and Defender definitions.

      * Every OTHER OS update (feature/version upgrades, non-security quality
        rollups, .NET, etc.) is offered to the user, who chooses:
            1. Install now
            2. Delay 1 week
            3. Delay 2 weeks
            4. Delay 4 weeks
            5. Delay 1 year
        A delay writes a "snooze until" timestamp to
        C:\ProgramData\WindowsUpdateCheck\snooze.txt. The weekly -Notify task
        stops prompting for these until that timestamp passes — but STILL
        installs security updates each week regardless of the snooze.

    Hardware DRIVERS are handled separately by Update-Drivers.ps1, which
    first-boot-tweaks.ps1 now also runs automatically (drivers install
    straight away too).

    To run the query it briefly flips wuauserv to Manual and starts it, then
    puts wuauserv back exactly how it found it (Disabled on this image).
    NoAutoUpdate stays set the whole time; it only blocks AUTOMATIC updating,
    not this explicit, on-demand call.

    MODES (mutually exclusive; default is -Interactive):
      -Auto         Install ALL offered OS updates (security + the rest) with
                    no prompts. For a hands-off full refresh.
      -Interactive  Install security automatically, then show the Install /
                    delay menu for any remaining non-security OS updates.
      -Notify       Silent scan. Install any security updates straight away.
                    Then, if non-security OS updates are offered AND no delay
                    is active, show a toast and open the -Interactive window.
                    Otherwise finish silently. This is what the weekly task runs.

    Every failure is non-fatal and logged to
    C:\ProgramData\WindowsUpdateCheck\windows-update.log.

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

# ── Logging + state ──────────────────────────────────────────────────────────
$StateDir   = Join-Path $env:ProgramData "WindowsUpdateCheck"
$LogFile    = Join-Path $StateDir "windows-update.log"
$SnoozeFile = Join-Path $StateDir "snooze.txt"
New-Item -ItemType Directory -Path $StateDir -Force -ErrorAction SilentlyContinue | Out-Null
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

# ── Snooze helpers ─────────────────────────────────────────────────────────
# The snooze is a single ISO-8601 timestamp: NON-SECURITY update prompts are
# suppressed until it passes. Security updates ignore it entirely. This is how
# the delay options are enforced, since Windows Update's own pause policies do
# nothing here (the WU services are disabled and we call the COM API directly,
# which ignores them).
function Get-SnoozeUntil {
    if (-not (Test-Path $SnoozeFile)) { return $null }
    try {
        $raw = (Get-Content -Path $SnoozeFile -Raw -ErrorAction Stop).Trim()
        if (-not $raw) { return $null }
        return [datetime]::Parse($raw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
    } catch {
        Write-Log "  Could not read snooze file (ignoring): $_" "Yellow"
        return $null
    }
}
function Set-Snooze {
    param([timespan]$Span, [string]$Label)
    $until = (Get-Date).Add($Span)
    try {
        Set-Content -Path $SnoozeFile -Value $until.ToString("o") -Encoding UTF8 -ErrorAction Stop
        Write-Log "  Non-security update prompts delayed by $Label — will not ask again until $($until.ToString('yyyy-MM-dd HH:mm')). Security updates still install." "Cyan"
    } catch {
        Write-Log "  Could not write snooze file: $_" "Yellow"
    }
}
function Clear-Snooze {
    if (Test-Path $SnoozeFile) {
        try { Remove-Item -Path $SnoozeFile -Force -ErrorAction Stop; Write-Log "  Cleared active update delay." } catch {}
    }
}

# ── Classify an update as security or not ──────────────────────────────────
# Security = has an MSRC severity (only set on security updates), OR is in the
# "Security Updates" or Defender "Definition Updates" category. The monthly
# cumulative security update and Defender definitions both match here.
$script:SecurityCategoryIds = @(
    '0fa1201d-4330-4fa8-8ae9-b877473b6441',  # Security Updates
    'e0789628-ce08-4437-be74-2495b842f43b'   # Definition Updates (Defender)
)
function Test-IsSecurityUpdate {
    param($Update)
    try { if ($Update.MsrcSeverity) { return $true } } catch {}
    try {
        foreach ($cat in $Update.Categories) {
            if ($script:SecurityCategoryIds -contains $cat.CategoryID) { return $true }
        }
    } catch {}
    return $false
}

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

# ── Temporarily allow the WU agent to run ──────────────────────────────────
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
        Write-Log "  wuauserv temporarily Manual+started for the update query (was $orig)."
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

# ── Search the WU catalog for OS (software) updates ─────────────────────────
# Returns the raw ISearchResult; the caller inspects .Updates.
function Search-WindowsUpdates {
    Write-Log "  Searching the Windows Update catalog (Type='Software' only)..."
    $session  = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    # "IsInstalled=0 and Type='Software' and IsHidden=0" restricts the result to
    # not-yet-installed OS updates (cumulative/quality, .NET, Defender, feature
    # updates) and excludes hardware drivers, which Update-Drivers.ps1 owns.
    $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    return @{ Session = $session; Result = $result }
}

# ── Download + install a chosen set of updates ─────────────────────────────
function Install-UpdateSet {
    param($Session, $Updates)   # $Updates = array of IUpdate

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $Updates) {
        try { if (-not $u.EulaAccepted) { $u.AcceptEula() } } catch {}
        $coll.Add($u) | Out-Null
    }

    Write-Log "  Downloading $($coll.Count) update package(s)..."
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
    Write-Log "  Opening the interactive update window..."
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$SelfPath`"", "-Interactive") `
        -Verb RunAs -ErrorAction SilentlyContinue
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
Write-Log "==== Update-Windows.ps1 ($Mode) starting ===="

$origStart = Enable-WuAgent
$exitCode  = 0
$rebootNeeded = $false
try {
    $search  = Search-WindowsUpdates
    $updates = @($search.Result.Updates)
    Write-Log "  $($updates.Count) Windows update(s) offered."

    # Split into security (install now) and the rest (prompt / delay).
    $security = @($updates | Where-Object { Test-IsSecurityUpdate $_ })
    $optional = @($updates | Where-Object { -not (Test-IsSecurityUpdate $_) })
    Write-Log "    $($security.Count) security, $($optional.Count) other OS update(s)."

    # 1. SECURITY — install straight away, every mode, ignoring any delay.
    if ($security.Count -gt 0) {
        Write-Log "  Installing $($security.Count) security update(s) automatically..." "Green"
        foreach ($u in $security) { Write-Log "    [security] $($u.Title)" }
        $ir = Install-UpdateSet -Session $search.Session -Updates $security
        if ($ir.RebootRequired) { $rebootNeeded = $true }
    }

    # 2. OTHER OS UPDATES — depends on mode.
    if ($optional.Count -eq 0) {
        Write-Log "  No non-security OS updates to offer." "Green"
    }
    elseif ($Mode -eq "Auto") {
        # Hands-off full refresh: install these too, no prompt.
        Write-Log "  Installing $($optional.Count) other OS update(s) automatically (-Auto)..."
        foreach ($u in $optional) { Write-Log "    $($u.Title)" }
        $ir = Install-UpdateSet -Session $search.Session -Updates $optional
        Clear-Snooze
        if ($ir.RebootRequired) { $rebootNeeded = $true }
    }
    elseif ($Mode -eq "Notify") {
        # Weekly task: don't install these here. If a delay is active, stay
        # silent; otherwise notify + hand off to a visible window for the choice.
        $snoozeUntil = Get-SnoozeUntil
        if ($snoozeUntil -and (Get-Date) -lt $snoozeUntil) {
            Write-Log "  $($optional.Count) non-security update(s) held back — delayed until $($snoozeUntil.ToString('yyyy-MM-dd HH:mm'))." "Cyan"
        } else {
            $names = ($optional | ForEach-Object { $_.Title }) -join "; "
            Write-Log "  Non-security updates offered: $names"
            Show-Toast -Title "$($optional.Count) Windows update(s) available" `
                       -Body  "Minimal Gaming found new Windows updates. A window will open to install them or delay."
            Restore-WuAgent -Orig $origStart   # let the child re-enable it itself
            Start-InteractiveWindow
            if ($rebootNeeded) {
                Show-Toast -Title "Restart needed" -Body "Security updates were installed. Restart when convenient to finish."
            }
            Write-Log "==== Update-Windows.ps1 (Notify) finished — handed off to interactive window ===="
            exit 0
        }
    }
    else {
        # Interactive — the "new update detected" menu (non-security only).
        Write-Host ""
        if ($security.Count -gt 0) {
            Write-Host "Installed $($security.Count) security update(s) automatically." -ForegroundColor Green
            Write-Host ""
        }
        Write-Host "The following (non-security) Windows updates are available:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $optional.Count; $i++) {
            Write-Host ("  {0}. {1}" -f ($i + 1), $optional[$i].Title)
        }
        Write-Host ""
        Write-Host "What would you like to do?" -ForegroundColor Cyan
        Write-Host "  1. Install now"
        Write-Host "  2. Delay 1 week"
        Write-Host "  3. Delay 2 weeks"
        Write-Host "  4. Delay 4 weeks"
        Write-Host "  5. Delay 1 year"
        Write-Host ""
        $answer = Read-Host "Enter choice [1-5]"

        switch ($answer.Trim()) {
            "1" {
                $ir = Install-UpdateSet -Session $search.Session -Updates $optional
                Clear-Snooze
                if ($ir.RebootRequired) { $rebootNeeded = $true }
                Write-Host "Done." -ForegroundColor Green
            }
            "2" { Set-Snooze -Span ([TimeSpan]::FromDays(7))   -Label "1 week" }
            "3" { Set-Snooze -Span ([TimeSpan]::FromDays(14))  -Label "2 weeks" }
            "4" { Set-Snooze -Span ([TimeSpan]::FromDays(28))  -Label "4 weeks" }
            "5" { Set-Snooze -Span ([TimeSpan]::FromDays(365)) -Label "1 year" }
            default {
                Write-Log "  No valid choice entered ('$answer') — treating as 'ask again next week'."
                Set-Snooze -Span ([TimeSpan]::FromDays(7)) -Label "1 week (default)"
            }
        }

        if ($rebootNeeded) {
            Write-Host ""
            Write-Host "A reboot is required to finish installing one or more updates." -ForegroundColor Yellow
            $rb = Read-Host "Reboot now? [Y]es / [N]o"
            if ($rb -match '^(y|yes)$') { Restart-Computer -Force }
        }
        Write-Host ""
        Write-Host "Press Enter to close..." -ForegroundColor DarkGray
        [void](Read-Host)
    }

    if ($rebootNeeded) { Write-Log "  A reboot is required to finish installing one or more updates." "Yellow" }
}
catch {
    Write-Log "  Windows update run failed (non-fatal): $_" "Red"
    $exitCode = 1
}
finally {
    Restore-WuAgent -Orig $origStart
}

Write-Log "==== Update-Windows.ps1 ($Mode) finished ===="
exit $exitCode
