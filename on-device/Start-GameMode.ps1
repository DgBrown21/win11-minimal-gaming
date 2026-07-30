<#
.SYNOPSIS
    Login launcher that boots this machine straight into Steam Big Picture.

.DESCRIPTION
    ARCHITECTURE (the "JohnMBooth hybrid"): the machine does NOT replace the
    Windows shell. explorer.exe stays the real Winlogon\Shell, so Windows
    itself starts the desktop (Progman + taskbar + wallpaper) the normal,
    fully-painted way. This script is NOT the shell — it's a per-user Startup
    item that simply launches Big Picture on top of the real desktop.

    WHY THIS AND NOT A SHELL SWAP: the earlier design of this project made
    powershell the Winlogon\Shell and hand-launched explorer.exe. Testing
    (multiple reboots) proved an explorer.exe started that way — especially
    when restarted after Big Picture's exclusive-fullscreen released — does
    NOT take over the desktop shell role: it came up as a bare File Explorer
    *window* with no wallpaper and no taskbar, and a forced display modeset
    (CDS_RESET) did not fix it, because the problem was never the display, it
    was that explorer was a child process rather than the shell. Making
    explorer the real shell removes the entire black/dead-desktop bug class:
    exiting Big Picture just returns to a desktop Windows has been painting
    all along. This matches what mature game-launcher-shell projects settled
    on independently — e.g. quangmach/GameLauncherShell explicitly abandoned
    explorer shell-replacement in its 2.0 rewrite over the same explorer
    artifact/on-screen-keyboard issues, and caffeinateddragonware/
    windowshandheldmod likewise keeps a real shell and layers the launcher on
    top behind a boot animation.

    THE SPLASH: because this runs from the Startup folder, the real desktop is
    briefly visible before Big Picture covers it. A topmost fullscreen loader
    (Show-BootLoader.ps1 — the animated "GAMING" logo with a progress ring and
    a spinning light, the same one first boot uses) is shown the instant this
    script starts and closed only once Big Picture has had time to paint, so
    the transition reads console-like. If that loader script isn't present for
    any reason, this falls back to a plain black splash. Either way there's a
    hard timeout so a missing/broken Steam just drops to the (working) real
    desktop instead of stranding on the splash.

    No watchdog loop lives here: explorer being the real shell means Windows
    keeps the desktop alive, and exiting Big Picture needs no repaint trickery.
    This script's job ends once the splash is dismissed.

    RE-ENTRY: the "Game Mode" desktop shortcut (Enter-GameMode.cmd) runs this
    same script, so dropping to the desktop and clicking it returns to Big
    Picture with the same splash.
#>

$LogFile = Join-Path $env:ProgramData "GameModeShell.log"
function Write-Log {
    param([string]$Message)
    try {
        Add-Content -Path $LogFile -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message) -ErrorAction SilentlyContinue
    } catch {}
}

function Set-BootStatus {
    param([string]$Path, [string]$Text)
    # FileShare.ReadWrite so the loader's polling and this write never collide
    # (matters most for the "__DONE__" sentinel actually landing).
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try { $sw = New-Object System.IO.StreamWriter($fs); $sw.Write($Text); $sw.Flush() } finally { $fs.Dispose() }
    } catch {}
}

Write-Log "==== Start-GameMode launcher starting (explorer is the real shell) ===="

# ── Boot splash — the shared animated "GAMING" loader, driven by a status file ──
# Preferred path: launch Show-BootLoader.ps1 (copied next to this script in
# ProgramData\GameMode by first-boot-tweaks.ps1) as a separate topmost process
# and steer it via a one-line status file. Fallback: if that script isn't
# present, show a plain black splash so we still mask the desktop flash.
try { Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop } catch {}
$GameModeDir = Join-Path $env:ProgramData "GameMode"
$LoaderScript = Join-Path $GameModeDir "Show-BootLoader.ps1"
$StatusFile   = Join-Path $GameModeDir "boot-status.txt"
$loaderProc = $null
$splashForm = $null

if (Test-Path $LoaderScript) {
    try {
        New-Item -ItemType Directory -Path $GameModeDir -Force -ErrorAction SilentlyContinue | Out-Null
        Set-BootStatus -Path $StatusFile -Text "Loading Steam Big Picture..."
        $loaderProc = Start-Process powershell.exe -PassThru -ArgumentList @(
            "-NoLogo","-NoProfile","-WindowStyle","Hidden","-ExecutionPolicy","Bypass",
            "-File","`"$LoaderScript`"","-StatusFile","`"$StatusFile`"","-TimeoutSeconds","120"
        )
        Write-Log "Animated GAMING loader shown (PID $($loaderProc.Id))"
    } catch {
        Write-Log "Could not start the animated loader, falling back to plain splash: $_"
        $loaderProc = $null
    }
}

if (-not $loaderProc) {
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
        Write-Log "Plain boot splash shown (loader script not present)"
    } catch {
        Write-Log "Could not show boot splash (non-fatal, desktop may be briefly visible): $_"
        $splashForm = $null
    }
}

# ── Launch Steam straight into Big Picture ──
$steamExe = "${env:ProgramFiles(x86)}\Steam\steam.exe"
try {
    if (Test-Path $steamExe) {
        # -bigpicture boots Steam STRAIGHT into Big Picture on a cold start,
        # faster than opening the normal client and then navigating to Big
        # Picture through the steam:// protocol handler.
        Start-Process -FilePath $steamExe -ArgumentList "-bigpicture"
        Write-Log "Launched Steam Big Picture"
    } else {
        Write-Log "Steam not found at $steamExe - dropping to desktop"
    }
} catch {
    Write-Log "Failed to launch Steam Big Picture: $_"
}

# ── Hold the splash until Big Picture's UI is up (capped) then reveal ──
try {
    $waitedMs = 0
    while ($waitedMs -lt 25000 -and -not (Get-Process -Name steamwebhelper -ErrorAction SilentlyContinue)) {
        Start-Sleep -Milliseconds 500
        [System.Windows.Forms.Application]::DoEvents()
        $waitedMs += 500
    }
    Start-Sleep -Seconds 2   # let Big Picture actually paint before revealing it
    if ($loaderProc) {
        Set-BootStatus -Path $StatusFile -Text "__DONE__"
        Start-Sleep -Milliseconds 750
        if (-not $loaderProc.HasExited) { $loaderProc.CloseMainWindow() | Out-Null }
        if (-not $loaderProc.HasExited) { Stop-Process -Id $loaderProc.Id -Force -ErrorAction SilentlyContinue }
    } elseif ($splashForm) {
        $splashForm.Close()
    }
    Write-Log "Boot splash dismissed after ~$([math]::Round($waitedMs/1000))s"
} catch {
    Write-Log "Error dismissing splash (non-fatal): $_"
    try { if ($loaderProc -and -not $loaderProc.HasExited) { Stop-Process -Id $loaderProc.Id -Force -ErrorAction SilentlyContinue } } catch {}
    try { if ($splashForm) { $splashForm.Close() } } catch {}
}
