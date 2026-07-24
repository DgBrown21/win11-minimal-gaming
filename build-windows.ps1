<#
.SYNOPSIS
    Builds Win11-Minimal.iso — a heavily size-reduced, gaming-focused
    Windows 11 Pro install ISO.

.DESCRIPTION
    Fetches the official Windows 11 ISO straight from Microsoft (same
    official API sequence used by the sibling Win11-Install project's
    build script), mounts it, extracts it, runs slim-image.ps1 against the
    extracted install.wim (the actual size-reduction work — see that
    script's header for what it does and why), injects autounattend.xml
    and first-boot-tweaks.ps1, then rebuilds a bootable ISO with
    oscdimg.exe (Microsoft's own tool, part of the free Windows ADK
    "Deployment Tools" feature).

    Needs roughly 40GB of free scratch space: the downloaded ISO (~8.5GB),
    the extracted copy (~8GB), WIM export/mount working space (can grow
    several GB during servicing), the final ESD (~3.5-4.5GB, see
    slim-image.ps1's honest size-expectation note), and the final rebuilt
    ISO (~3.5-4.5GB).

    UNVERIFIED: written without a prior test run — same caveat as the
    sibling project's Windows scripts. The whole pipeline should be
    considered unproven until it has actually been run end-to-end and the
    resulting ISO boot-tested in a VM (see README.md's verification
    section) — do not flash this to physical install media or use on real
    hardware before that.

.PARAMETER OscdimgPath
    Full path to oscdimg.exe, if it's not at the standard Windows ADK
    install location. Get the ADK (free) from:
    https://learn.microsoft.com/windows-hardware/get-started/adk-install
    — you only need the "Deployment Tools" feature, not the whole ADK.

.PARAMETER WinSkuId
    Microsoft's internal SKU id for the ISO language/edition combo.
    20047 = Windows 11 25H2 English International (UK) — the default,
    matches autounattend.xml's en-GB settings.

.PARAMETER SkipDownload
    If a previous run already downloaded build\windows11.iso, reuse it
    instead of fetching again (handshake links expire in ~24h, and
    re-running the whole build while iterating on slim-image.ps1 is slow
    otherwise).
#>
param(
    [string]$OscdimgPath = "${env:ProgramFiles(x86)}\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\amd64\Oscdimg\oscdimg.exe",
    [string]$WinSkuId = "20047",
    [switch]$SkipDownload
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BuildDir = Join-Path $ScriptDir "build"
$OutIso = Join-Path $ScriptDir "Win11-Minimal.iso"

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "[ERR] This script must run elevated — the slim-image.ps1 stage needs Mount-WindowsImage/DISM, which require Administrator." -ForegroundColor Red
    Write-Host "Re-launch an elevated PowerShell and try again." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $OscdimgPath)) {
    Write-Host "[ERR] oscdimg.exe not found at $OscdimgPath" -ForegroundColor Red
    Write-Host "Install the free Windows ADK 'Deployment Tools' feature from:" -ForegroundColor Yellow
    Write-Host "  https://learn.microsoft.com/windows-hardware/get-started/adk-install" -ForegroundColor Yellow
    Write-Host "...or pass -OscdimgPath if it's installed somewhere else." -ForegroundColor Yellow
    exit 1
}

New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null
Set-Location $BuildDir

$isoDownloadPath = Join-Path $BuildDir "windows11.iso"

# ── 1. Resolve a download link from Microsoft, unless reusing a prior download ──
if ($SkipDownload -and (Test-Path $isoDownloadPath)) {
    Write-Host "==> -SkipDownload set and $isoDownloadPath already exists — reusing it."
} else {
    Write-Host "==> Fetching a download link for SKU $WinSkuId from Microsoft..."
    $OrgId = "y6jn8c31"
    $ProfileId = "606624d44113"
    $InstanceId = "560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"
    $SessionId = [guid]::NewGuid().ToString()
    $ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"

    $webSession = $null
    Invoke-WebRequest -UseBasicParsing -SessionVariable webSession -UserAgent $ua `
        -Uri "https://vlscppe.microsoft.com/tags?org_id=$OrgId&session_id=$SessionId" | Out-Null

    $mdt = Invoke-RestMethod -UseBasicParsing -WebSession $webSession -UserAgent $ua `
        -Uri "https://ov-df.microsoft.com/mdt.js?instanceId=$InstanceId&PageId=si&session_id=$SessionId"
    $w = $null; $rticks = $null
    if ($mdt -match '[?&]w=([A-F0-9]+)') { $w = $matches[1] }
    if ($mdt -match 'rticks="\+?(\d+)') { $rticks = $matches[1] }
    if (-not $w -or -not $rticks) {
        throw "Could not extract the w/rticks values from Microsoft's anti-bot handshake — their API may have changed since this script was written."
    }

    $mdtNow = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    Invoke-WebRequest -UseBasicParsing -WebSession $webSession -UserAgent $ua `
        -Uri "https://ov-df.microsoft.com/?session_id=$SessionId&CustomerId=$InstanceId&PageId=si&w=$w&mdt=$mdtNow&rticks=$rticks" | Out-Null

    $linksRaw = Invoke-RestMethod -UseBasicParsing -WebSession $webSession -UserAgent $ua `
        -Headers @{ "Accept" = "application/json"; "Referer" = "https://www.microsoft.com/software-download/windows11" } `
        -Uri "https://www.microsoft.com/software-download-connector/api/GetProductDownloadLinksBySku?profile=$ProfileId&productEditionId=undefined&SKU=$WinSkuId&friendlyFileName=undefined&Locale=en-US&sessionID=$SessionId"
    $links = if ($linksRaw -is [string]) { $linksRaw | ConvertFrom-Json } else { $linksRaw }
    $url = $links.ProductDownloadOptions[0].Uri
    if (-not $url) {
        throw "No download link returned — Microsoft may have rate-limited this session (their anti-bot layer is IP/session based). Wait a while and retry."
    }

    Write-Host "==> Got a link (expires in ~24h). Downloading..."
    Invoke-WebRequest -Uri $url -OutFile $isoDownloadPath
}

# ── 2. Mount the ISO — Windows reads its UDF format natively ────────────
# Deliberately NOT using Get-Volume here to resolve the drive letter — it
# depends on the Storage Management CIM provider, which is unavailable in
# some remote/non-interactive PowerShell sessions (returns empty results
# even for pre-existing drives, not just the freshly mounted one). Diffing
# [System.IO.DriveInfo]'s CD-ROM list before/after mount works regardless.
Write-Host "==> Mounting and copying source files..."
$isoPath = (Resolve-Path $isoDownloadPath).Path
$cdromsBefore = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "CDRom" } | ForEach-Object { $_.Name }
Mount-DiskImage -ImagePath $isoPath | Out-Null
Start-Sleep -Seconds 2
$cdromsAfter = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq "CDRom" -and $_.IsReady } | ForEach-Object { $_.Name }
$sourceRoot = $cdromsAfter | Where-Object { $cdromsBefore -notcontains $_ } | Select-Object -First 1
if (-not $sourceRoot) { $sourceRoot = $cdromsAfter | Select-Object -First 1 }
if (-not $sourceRoot) { throw "Could not find the drive letter Windows assigned to the mounted ISO — check Get-DiskImage/manually mounted drives." }
Write-Host "  Mounted at $sourceRoot"

$extractDir = Join-Path $BuildDir "extracted"
Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $extractDir | Out-Null
Copy-Item -Path "$sourceRoot*" -Destination $extractDir -Recurse -Force

Dismount-DiskImage -ImagePath $isoPath

# ── 3. Slim install.wim down (offline DISM servicing) ───────────────────
# This is the actual size-reduction work — see slim-image.ps1's header.
# It's a separate script (not inlined) specifically so it can be re-run
# standalone against an already-extracted folder while iterating, without
# re-downloading/re-extracting the ~8.5GB source ISO every time.
Write-Host "==> Slimming install.wim (this is the slow part — see slim-image.ps1, expect 1-2+ hours)..."
& (Join-Path $ScriptDir "slim-image.ps1") -ExtractDir $extractDir
if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne $null) {
    throw "slim-image.ps1 failed (exit $LASTEXITCODE) — check the output above before continuing."
}

# ── 4. Inject autounattend.xml + $OEM$ first-boot script ─────────────────
Write-Host "==> Injecting autounattend.xml and `$OEM`$ first-boot script..."
Copy-Item (Join-Path $ScriptDir "autounattend.xml") (Join-Path $extractDir "autounattend.xml") -Force
$oemScripts = Join-Path $extractDir "sources\`$OEM`$\`$`$\Setup\Scripts"
New-Item -ItemType Directory -Path $oemScripts -Force | Out-Null
Copy-Item (Join-Path $ScriptDir "first-boot-tweaks.ps1") $oemScripts -Force

# ── 5. Rebuild with oscdimg ───────────────────────────────────────────────
# -m: ignore the (irrelevant here) max-image-size limit
# -o: dedupe identical files to save space
# -u2 -udfver102: UDF revision 1.02, matching what real Windows ISOs use —
#   lets install.esd sit as one file with no splitting needed
# -bootdata: dual boot catalog entries — platform 0 (BIOS, etfsboot.com)
#   and platform 0xEF (UEFI, efisys_noprompt.bin — no-keypress-prompt
#   variant, the right choice for USB rather than optical media)
Write-Host "==> Rebuilding as a hybrid BIOS+UEFI bootable ISO..."
$bootData = '2#p0,e,b"{0}\boot\etfsboot.com"#pEF,e,b"{0}\efi\microsoft\boot\efisys_noprompt.bin"' -f $extractDir
# oscdimg writes its normal progress output to stderr, not just actual
# errors — with the global $ErrorActionPreference = "Stop" in effect,
# PowerShell 5.1 treats ANY stderr line from a native command as a
# terminating NativeCommandError regardless of exit code, which threw here
# even on a fully successful run (confirmed: the ISO was written correctly
# despite the reported "failure"). Relying on $LASTEXITCODE — already the
# actual failure check below — requires not treating stderr as fatal first.
$prevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
& $OscdimgPath -m -o -u2 -udfver102 "-bootdata:$bootData" -lCCCOMA_X64FRE_EN-GB_DV9 $extractDir $OutIso
$ErrorActionPreference = $prevEAP
if ($LASTEXITCODE -ne 0) {
    throw "oscdimg failed (exit $LASTEXITCODE) — check the output above."
}

$finalSizeGB = [math]::Round((Get-Item $OutIso).Length / 1GB, 2)
Remove-Item $extractDir -Recurse -Force

Write-Host ""
Write-Host "==> Done: $OutIso (${finalSizeGB}GB)" -ForegroundColor Green
Write-Host "==> Do NOT flash to physical media / use on real hardware yet — boot-test this in a VM first. See README.md's verification section." -ForegroundColor Yellow
