<#
.SYNOPSIS
    Fullscreen "GAMING" boot loader — a black, topmost splash with a moving
    3D starfield, a big GAMING logo, a progress ring with a light spinning
    around it, and a live status line underneath ("GAME MODE" + whatever is
    currently being loaded/installed).

.DESCRIPTION
    Purpose-built to cover the real desktop the instant it can, so the brief
    desktop flash before Steam Big Picture paints (normal logins) — and the
    whole first-boot install phase (drivers, Steam, apps) — read as a single
    console-style loading screen rather than a visible Windows desktop doing
    setup.

    THE STARFIELD: behind the logo, stars stream out of the centre of the
    screen toward the viewer (a classic "warp"/hyperspace field). Each star is
    a 3D point (x, y, depth) projected with perspective (screen = centre +
    xy / depth). As a star's depth shrinks it drifts outward and speeds up, so
    — exactly as asked — stars near the centre move slowly and stars out toward
    the edges move fast. Sizes and positions are randomised per star, and each
    respawns at the far plane once it passes the camera, so the field never
    thins out. It's all drawn in the same double-buffered paint pass as the
    ring, so it animates smoothly while the caller does blocking installs.

    It is intentionally a SEPARATE process driven by a status FILE, not an
    in-process form: the caller (first-boot-tweaks.ps1) is doing long blocking
    installs on its own thread and can't also pump a UI message loop, so it
    just writes one line of status to $StatusFile as it progresses and this
    process animates smoothly and reflects it. Signal completion by writing the
    literal token "__DONE__" to the status file (or deleting it) and the loader
    closes, revealing whatever the caller launched (Big Picture, or the
    desktop as a fallback).

    explorer.exe remains the real Windows shell throughout — this is only a
    window layered on top. Nothing here changes the shell.

.PARAMETER StatusFile
    Path to the one-line status file this loader polls. The caller writes the
    current step there; "__DONE__" (or the file being removed) closes the loader.

.PARAMETER Title
    Big centered logo text inside the ring. Default "GAMING".

.PARAMETER Subtitle
    Heading under the ring. Default "GAME MODE".

.PARAMETER TimeoutSeconds
    Hard safety cap — the loader self-closes after this long even if it never
    sees "__DONE__", so a broken/killed caller can never strand the machine on
    the splash. Generous by default because first-boot driver+app installs can
    take a while.
#>
param(
    [string]$StatusFile     = (Join-Path $env:ProgramData "GameMode\boot-status.txt"),
    [string]$Title          = "GAMING",
    [string]$Subtitle       = "GAME MODE",
    [int]   $TimeoutSeconds = 3600
)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ── Shared animation/state (script scope so the timer + paint handler share it) ──
$script:angle    = 0                       # current rotation of the spinning light (degrees)
$script:status   = "Starting Game Mode..." # last status line read from the file
$script:started  = Get-Date
$script:accent   = [System.Drawing.Color]::FromArgb(255,  76, 194, 255)  # cyan-blue "light"
$script:accentDim= [System.Drawing.Color]::FromArgb(255,  38,  42,  50)  # dim base ring
$script:tick     = 0                       # frame counter (used to re-assert topmost)

# ── Starfield tunables ───────────────────────────────────────────────────────
$script:starCount = 220     # how many stars are alive at once
$script:warpSpeed = 0.010   # depth travelled toward the camera each frame (bigger = faster warp)
$script:zNear     = 0.045   # depth at which a star has "passed" the camera and respawns
$script:rng       = New-Object System.Random

function Read-Status {
    # Open with FileShare.ReadWrite so a concurrent writer (the caller updating
    # the status, including the "__DONE__" sentinel) never collides with our
    # ~30 Hz polling. A rare partial/empty read just leaves the status unchanged
    # for one tick and self-corrects on the next.
    try {
        $fs = [System.IO.File]::Open($StatusFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            return $sr.ReadToEnd().Trim()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

# Spawn/reset one star at the far plane with a fresh random position, size and
# colour. Stars are hashtables of normalised coords: X/Y in [-1,1], Z depth in
# (0,1] (1 = far, ~0 = right at the camera).
function New-Star {
    param($star)
    if (-not $star) { $star = @{} }
    $star.X = $script:rng.NextDouble() * 2.0 - 1.0
    $star.Y = $script:rng.NextDouble() * 2.0 - 1.0
    $star.Z = 1.0
    $star.Base = $script:rng.NextDouble() * 1.2 + 0.5   # base radius multiplier 0.5..1.7
    # Mostly cool white, a few warm-white and a few accent-cyan for depth.
    $roll = $script:rng.NextDouble()
    if     ($roll -lt 0.14) { $star.R = 120; $star.G = 200; $star.B = 255 }  # cyan
    elseif ($roll -lt 0.26) { $star.R = 255; $star.G = 244; $star.B = 224 }  # warm white
    else                    { $star.R = 226; $star.G = 236; $star.B = 255 }  # cool white
    return $star
}

# Seed from any status already written before we started.
$seed = Read-Status
if ($seed -and $seed -ne "__DONE__") { $script:status = $seed }

# ── The fullscreen black form ────────────────────────────────────────────────
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.WindowState     = [System.Windows.Forms.FormWindowState]::Maximized
$form.BackColor       = [System.Drawing.Color]::Black
$form.TopMost         = $true
$form.ShowInTaskbar   = $false
$form.KeyPreview      = $true
$form.Cursor          = [System.Windows.Forms.Cursors]::Default
$form.StartPosition   = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds          = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds

# Double-buffer the form (the DoubleBuffered/SetStyle members are protected —
# reach them via reflection) so the starfield + spinning ring animate without flicker.
try {
    $setStyle = [System.Windows.Forms.Control].GetMethod('SetStyle', [System.Reflection.BindingFlags]'Instance,NonPublic')
    $styles = [System.Windows.Forms.ControlStyles]::OptimizedDoubleBuffer -bor `
              [System.Windows.Forms.ControlStyles]::AllPaintingInWmPaint -bor `
              [System.Windows.Forms.ControlStyles]::UserPaint
    $setStyle.Invoke($form, @([Object]$styles, [Object]$true)) | Out-Null
} catch { }

# Layout + reusable GDI+ resources, computed once the (fixed) fullscreen size is known.
$script:ready = $false
$form.Add_Shown({
    $script:W  = $form.ClientSize.Width
    $script:H  = $form.ClientSize.Height
    $script:cx = [int]($script:W / 2)
    $script:cy = [int]($script:H * 0.40)                     # ring sits a little above centre
    $script:R  = [int]([math]::Min($script:W, $script:H) * 0.17)
    $t         = [math]::Max(6, [int]($script:R * 0.11))     # ring thickness

    # Starfield projection: stars radiate from the true screen centre.
    $script:scx       = [double]($script:W / 2)
    $script:scy       = [double]($script:H / 2)
    $script:projScale = [double]($script:W * 0.55)
    $script:stars = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $script:starCount; $i++) {
        $s = New-Star $null
        $s.Z = $script:rng.NextDouble() * 0.9 + 0.1          # stagger initial depths so the field is full at frame 0
        [void]$script:stars.Add($s)
    }
    # One reusable pen for every star streak (round caps => a zero-length streak
    # still renders as a dot); colour + width are set per star during paint.
    $script:starPen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [single]1)
    $script:starPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:starPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round

    $script:basePen = New-Object System.Drawing.Pen($script:accentDim, $t)
    $script:arcPen  = New-Object System.Drawing.Pen($script:accent, $t)
    $script:arcPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $script:arcPen.EndCap   = [System.Drawing.Drawing2D.LineCap]::Round
    $script:headBrush = New-Object System.Drawing.SolidBrush($script:accent)
    $script:whiteBrush= New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $script:subBrush  = New-Object System.Drawing.SolidBrush($script:accent)
    $script:statBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 170, 176, 188))

    # Title font, shrunk until "GAMING" fits comfortably inside the ring.
    $g = $form.CreateGraphics()
    $fs = [double]($script:R * 0.62)
    do {
        if ($script:titleFont) { $script:titleFont.Dispose() }
        $script:titleFont = New-Object System.Drawing.Font("Segoe UI", [single]$fs, [System.Drawing.FontStyle]::Bold)
        $sz = $g.MeasureString($Title, $script:titleFont)
        $fs -= 2
    } while ($sz.Width -gt ($script:R * 1.7) -and $fs -gt 10)
    $g.Dispose()

    $script:subFont  = New-Object System.Drawing.Font("Segoe UI", [single]([math]::Max(11, $script:R * 0.16)), [System.Drawing.FontStyle]::Bold)
    $script:statFont = New-Object System.Drawing.Font("Segoe UI", [single]([math]::Max(10, $script:R * 0.11)), [System.Drawing.FontStyle]::Regular)

    $script:centerFmt = New-Object System.Drawing.StringFormat
    $script:centerFmt.Alignment     = [System.Drawing.StringAlignment]::Center
    $script:centerFmt.LineAlignment = [System.Drawing.StringAlignment]::Center

    $script:ready = $true
    $form.Invalidate()
})

$form.Add_Paint({
    param($sender, $e)
    if (-not $script:ready) { return }
    $g = $e.Graphics
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::ClearTypeGridFit
    $g.Clear([System.Drawing.Color]::Black)

    # ── Starfield (drawn first, behind the ring/logo) ─────────────────────────
    $scx = $script:scx; $scy = $script:scy; $ps = $script:projScale
    foreach ($s in $script:stars) {
        $z = $s.Z
        $px = $scx + ($s.X / $z) * $ps
        $py = $scy + ($s.Y / $z) * $ps
        # Depth-driven look: nearer = bigger and brighter.
        $near   = 1.0 - $z
        $radius = [double]$s.Base * (0.4 + $near * 3.2)
        $alpha  = [int](40 + $near * 215); if ($alpha -gt 255) { $alpha = 255 }
        $script:starPen.Color = [System.Drawing.Color]::FromArgb($alpha, $s.R, $s.G, $s.B)
        $script:starPen.Width = [single]([math]::Max(1.0, $radius))
        # Streak from where the star was last frame to where it is now — the
        # motion trail that sells the "flying toward you" warp; round caps make
        # far/short streaks read as points.
        $zp  = $z + $script:warpSpeed
        $ppx = $scx + ($s.X / $zp) * $ps
        $ppy = $scy + ($s.Y / $zp) * $ps
        $g.DrawLine($script:starPen, [single]$ppx, [single]$ppy, [single]$px, [single]$py)
    }

    $R = $script:R; $cx = $script:cx; $cy = $script:cy
    $x = $cx - $R; $y = $cy - $R; $d = 2 * $R

    # Dim full base ring, then the bright rotating light arc on top of it.
    $g.DrawEllipse($script:basePen, $x, $y, $d, $d)
    $sweep = 80
    $g.DrawArc($script:arcPen, $x, $y, $d, $d, $script:angle, $sweep)

    # Bright leading "head" dot at the end of the arc, for the spinning-light feel.
    $headRad = ($script:angle + $sweep) * [math]::PI / 180.0
    $hx = $cx + $R * [math]::Cos($headRad)
    $hy = $cy + $R * [math]::Sin($headRad)
    $hr = [math]::Max(5, $R * 0.09)
    $g.FillEllipse($script:headBrush, [single]($hx - $hr), [single]($hy - $hr), [single](2 * $hr), [single](2 * $hr))

    # "GAMING" logo centred inside the ring.
    $titleRect = New-Object System.Drawing.RectangleF([single]($cx - $R), [single]($cy - $R), [single]$d, [single]$d)
    $g.DrawString($Title, $script:titleFont, $script:whiteBrush, $titleRect, $script:centerFmt)

    # "GAME MODE" heading + live status line beneath the ring.
    $subY  = $cy + $R + ($R * 0.35)
    $subRect = New-Object System.Drawing.RectangleF(0, [single]$subY, [single]$script:W, [single]($R * 0.4))
    $g.DrawString($Subtitle, $script:subFont, $script:subBrush, $subRect, $script:centerFmt)

    $statY = $subY + ($R * 0.45)
    $statRect = New-Object System.Drawing.RectangleF([single]($script:W * 0.15), [single]$statY, [single]($script:W * 0.70), [single]($R * 0.9))
    $g.DrawString($script:status, $script:statFont, $script:statBrush, $statRect, $script:centerFmt)
})

# ── Animation + status polling timer ─────────────────────────────────────────
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 33   # ~30 fps
$timer.Add_Tick({
    $script:angle = ($script:angle + 7) % 360

    # Advance the starfield: each star moves toward the camera; recycle it at
    # the far plane once it passes the camera or flies well off-screen.
    if ($script:stars) {
        foreach ($s in $script:stars) {
            $s.Z = $s.Z - $script:warpSpeed
            if ($s.Z -le $script:zNear -or
                [math]::Abs($s.X / $s.Z) -gt 2.4 -or
                [math]::Abs($s.Y / $s.Z) -gt 2.4) {
                New-Star $s | Out-Null
            }
        }
    }

    # Every ~half-second, re-assert topmost so nothing (a transient window, the
    # desktop repainting, Steam's own splash) can slip in front of the loader.
    $script:tick++
    if (($script:tick % 15) -eq 0) {
        try { $form.TopMost = $false; $form.TopMost = $true } catch {}
    }

    $s = Read-Status
    if ($s -eq "__DONE__") { $timer.Stop(); $form.Close(); return }
    elseif ($s) { $script:status = $s }

    if (((Get-Date) - $script:started).TotalSeconds -gt $TimeoutSeconds) {
        $timer.Stop(); $form.Close(); return
    }
    $form.Invalidate()
})

# Esc is a manual escape hatch (mainly for testing on a normal desktop).
$form.Add_KeyDown({ if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $timer.Stop(); $form.Close() } })

$form.Add_FormClosed({
    foreach ($r in @($script:starPen,$script:basePen,$script:arcPen,$script:headBrush,$script:whiteBrush,
                      $script:subBrush,$script:statBrush,$script:titleFont,$script:subFont,
                      $script:statFont,$script:centerFmt,$timer)) {
        try { if ($r) { $r.Dispose() } } catch {}
    }
})

$timer.Start()
[System.Windows.Forms.Application]::Run($form)
