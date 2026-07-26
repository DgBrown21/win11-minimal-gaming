<#
.SYNOPSIS
    Windows shell replacement (Winlogon\Shell) for a SteamOS-style Game Mode.

.DESCRIPTION
    Registered by first-boot-tweaks.ps1 as HKLM\SOFTWARE\Microsoft\Windows
    NT\CurrentVersion\Winlogon\Shell in place of explorer.exe. Windows logs
    the session off the moment its registered Shell process exits, so the
    watchdog loop below must never let an exception escape — every risky
    call is individually wrapped in try/catch for exactly that reason.

    MODE PERSISTENCE (added 2026-07-25, modeled on SteamOS's
    `steamos-session-select` — see steamdeck.ca's "always start in desktop
    mode" how-to): SteamOS boots into whichever session
    (gamescope-wayland.desktop vs plasma.desktop) you last selected, not
    unconditionally into Game Mode every time. This script does the same
    via a one-line state file at C:\ProgramData\GameMode\mode.txt
    ("game" or "desktop", defaults to "game" if missing):
      - Exiting Big Picture (Steam's process exiting) sets the file to
        "desktop" — the next boot goes straight to a normal desktop, no
        Big Picture autostart, no flash.
      - The "Game Mode" desktop shortcut (created by first-boot-tweaks.ps1)
        sets the file back to "game" AND launches Big Picture immediately.
    Windows has no real equivalent of swapping the login session the way
    SteamOS's display manager does — explorer.exe and Steam still both run
    in the same session here — so this is the closest practical match:
    right persisted default, minimal visible transition.

    BOOT SPLASH (added 2026-07-25): FOUND BY TESTING — launching
    explorer.exe first and Steam a few seconds later means the desktop is
    genuinely visible for those few seconds before Big Picture covers it,
    which doesn't match a real console boot. In "game" mode, a plain black
    topmost window is shown the instant this script starts and is only
    closed once Big Picture has had time to actually paint — the desktop
    still loads underneath (still needed for later), it's just never seen.

    Sequence in "game" mode: show the splash, launch explorer.exe (hidden
    behind the splash), launch Steam straight into Big Picture, wait for it
    to come up, then close the splash. From then on this script watches:
      - explorer.exe crashing outright — relaunched immediately.
      - The user returning to the desktop from Big Picture — explorer.exe is
        deliberately KILLED AND RESTARTED at that moment, not just left
        alone. FOUND BY TESTING (2026-07-25): the pre-launched explorer.exe
        instance often doesn't repaint its taskbar/desktop cleanly after Big
        Picture's exclusive-fullscreen mode releases the display — the
        process is still alive, but the user is left looking at nothing.
        Forcing a fresh explorer.exe instance at that exact moment
        guarantees a clean, visible desktop every time. This is also the
        moment the mode file flips to "desktop" (see above).

        CORRECTED (2026-07-26): the original build keyed this off steam.exe
        exiting, on the assumption (wrongly "confirmed by testing" on
        2026-07-25) that Big Picture's "Exit to Desktop" fully quits Steam.
        It does NOT on current Steam — the client stays running in the tray,
        so that trigger never fired and the user was stranded on a dead
        desktop with Big Picture gone. The return-to-desktop signal is now
        the foreground window becoming the desktop (explorer) after
        Steam/Big Picture held it; steam.exe fully exiting is kept only as a
        fallback. See the watchdog loop and Get-ForegroundProcessName below.

    RECOVERY: a broken edit here just degrades to a plain desktop with no
    Big Picture autostart (explorer.exe still launches first, independent
    of anything failing afterward). The only way this produces a black
    screen is if powershell.exe itself can't start at all. Recover from
    that by booting to Safe Mode / Safe Mode with Command Prompt and
    running:
        reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d explorer.exe /f
    If it boots but is stuck on the black splash (Steam missing/broken),
    the splash has its own hard timeout below and will drop to the desktop
    on its own — no separate recovery needed for that case.
#>

$LogFile = Join-Path $env:ProgramData "GameModeShell.log"
function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

$ModeFile = Join-Path $env:ProgramData "GameMode\mode.txt"
function Get-GameModeState {
    try {
        if (Test-Path $ModeFile) {
            $m = Get-Content -Path $ModeFile -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($m -eq "desktop") { return "desktop" }
        }
    } catch {}
    return "game"
}
function Set-GameModeState {
    param([string]$Mode)
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $ModeFile) -Force -ErrorAction SilentlyContinue | Out-Null
        Set-Content -Path $ModeFile -Value $Mode -ErrorAction SilentlyContinue
    } catch {}
}

# ── Foreground-window detection ───────────────────────────────────────────
# Used by the watchdog to notice the user has returned to the DESKTOP from Big
# Picture without relying on steam.exe fully exiting. FOUND BY TESTING
# (2026-07-26): current Steam does NOT terminate steam.exe on Big Picture's
# "Exit to Desktop" — it drops back to the desktop with the client still
# running in the tray, so the old "steam process exited" trigger never fired
# and the desktop was left un-repainted after exclusive-fullscreen released.
# Keying on the foreground window instead is resilient to that: when the
# desktop (explorer's Progman) becomes foreground after Steam/Big Picture had
# it, we force the clean explorer restart. Launching a GAME makes the game the
# foreground window (not explorer), so this deliberately does NOT fire then.
# If the P/Invoke can't compile the whole thing degrades to the original
# steam-exit-only behavior — never let this abort the shell.
$ForegroundAvailable = $false
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GameModeFg {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    public static uint ForegroundPid() {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return 0;
        uint pid; GetWindowThreadProcessId(h, out pid); return pid;
    }
}
'@ -ErrorAction Stop
    $ForegroundAvailable = $true
} catch {}

function Get-ForegroundProcessName {
    # Lowercased base process name of the current foreground window, or $null.
    if (-not $ForegroundAvailable) { return $null }
    try {
        $fgPid = [GameModeFg]::ForegroundPid()
        if ($fgPid -eq 0) { return $null }
        $p = Get-Process -Id ([int]$fgPid) -ErrorAction SilentlyContinue
        if ($p) { return $p.ProcessName.ToLowerInvariant() }
    } catch {}
    return $null
}

$mode = Get-GameModeState
Write-Log "==== GameModeShell starting (mode: $mode) ===="

# ── Boot splash — only in "game" mode, masks the explorer/Steam startup gap ──
$splashForm = $null
if ($mode -eq "game") {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $splashForm = New-Object System.Windows.Forms.Form
        $splashForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $splashForm.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
        $splashForm.BackColor = [System.Drawing.Color]::Black
        $splashForm.TopMost = $true
        $splashForm.ShowInTaskbar = $false
        $label = New-Object System.Windows.Forms.Label
        $label.Text = "Starting Game Mode..."
        $label.ForeColor = [System.Drawing.Color]::White
        $label.Font = New-Object System.Drawing.Font("Segoe UI", 24)
        $label.AutoSize = $true
        $splashForm.Controls.Add($label)
        $splashForm.Add_Shown({
            $label.Left = [int](($splashForm.ClientSize.Width - $label.Width) / 2)
            $label.Top = [int](($splashForm.ClientSize.Height - $label.Height) / 2)
        })
        $splashForm.Show()
        $splashForm.Refresh()
        Write-Log "Boot splash shown"
    } catch {
        Write-Log "Could not show boot splash (non-fatal, desktop may be briefly visible): $_"
        $splashForm = $null
    }
}

function Start-DesktopExplorer {
    try {
        Start-Process "explorer.exe"
        Write-Log "Launched explorer.exe"
    } catch {
        Write-Log "Failed to launch explorer.exe: $_"
    }
}

if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
    Start-DesktopExplorer
    Start-Sleep -Seconds 2
}

$steamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
$steamWasRunning = $false

if ($mode -eq "game") {
    try {
        if (Test-Path $steamExe) {
            Start-Process -FilePath $steamExe -ArgumentList "-start steam://open/bigpicture"
            Write-Log "Launched Steam Big Picture"
            $steamWasRunning = $true
        } else {
            Write-Log "Steam not found at $steamExe - staying on desktop"
        }
    } catch {
        Write-Log "Failed to launch Steam Big Picture: $_"
    }

    if ($splashForm) {
        # Wait for Big Picture's UI process to appear, capped so a slow or
        # missing Steam can't strand the user on a black screen forever.
        $waitedMs = 0
        while ($waitedMs -lt 25000 -and -not (Get-Process -Name steamwebhelper -ErrorAction SilentlyContinue)) {
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
            $waitedMs += 500
        }
        Start-Sleep -Seconds 2   # let Big Picture actually paint before revealing it
        try { $splashForm.Close() } catch {}
        Write-Log "Boot splash dismissed after ~$([math]::Round($waitedMs/1000))s"
    }
} else {
    Write-Log "Desktop Mode is the persisted default - not auto-launching Big Picture"
    if ($splashForm) { try { $splashForm.Close() } catch {} }
}

# Stay alive for the whole session — Winlogon logs the session off the
# instant this process exits, so the loop body must never let an exception
# escape, and the loop itself must never end.
#
# "Returned to desktop" is detected two ways (either one triggers the clean
# explorer restart + persist Desktop Mode):
#   1. Foreground window becomes the desktop (explorer) AFTER Steam/Big
#      Picture had held the foreground — the reliable signal for Big Picture's
#      "Exit to Desktop" now that steam.exe no longer quits (see header note).
#      $steamHadFocus re-arms only when Steam/Big Picture is foreground again,
#      so this fires once per return, not repeatedly while sitting on the
#      desktop, and NOT while a game is fullscreen (the game is foreground).
#   2. steam.exe fully exiting — the original trigger, kept as a fallback for
#      the case where the user does fully quit Steam.
$steamHadFocus = $false
while ($true) {
    try {
        Start-Sleep -Seconds 5

        if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
            Write-Log "explorer.exe not running - relaunching"
            Start-DesktopExplorer
        }

        $fg = Get-ForegroundProcessName
        if ($fg -eq "steam" -or $fg -eq "steamwebhelper") { $steamHadFocus = $true }
        $returnedToDesktop = ($steamHadFocus -and $fg -eq "explorer")

        $steamRunningNow = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
        $steamJustExited = ($steamWasRunning -and -not $steamRunningNow)

        if ($returnedToDesktop -or $steamJustExited) {
            # Big Picture's "Exit to Desktop" (steam may or may not still be
            # running) - force a clean repaint by restarting explorer.exe
            # rather than trusting the pre-launched instance to redraw its
            # taskbar/desktop on its own after exclusive-fullscreen releases,
            # and persist Desktop Mode so the next boot doesn't force Big
            # Picture again (see header note above).
            $why = if ($steamJustExited) { "Steam exited" } else { "desktop regained foreground" }
            Write-Log "Exit to Desktop detected ($why) - restarting explorer.exe for a clean desktop, persisting Desktop Mode"
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 1
            Start-DesktopExplorer
            Set-GameModeState "desktop"
            # Re-arm: only fire again once Steam/Big Picture is foreground anew.
            $steamHadFocus = $false
        }
        $steamWasRunning = $steamRunningNow
    } catch {
        Write-Log "Watchdog loop error (non-fatal, continuing): $_"
    }
}
