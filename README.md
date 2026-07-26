# Windows 11 Pro — Minimal Gaming Build

Builds a heavily size-reduced Windows 11 Pro install ISO aimed purely at
PC gaming: local account only, no Microsoft Account, no Edge (removed
offline), no OneDrive, no bundled apps/features beyond what a gaming box
needs, aggressively telemetry-free, a performance power plan by default,
Windows Defender kept working, Windows Update disabled. Boots straight into
Steam Big Picture with explorer.exe still the real shell. Built for
bare-metal installs on hardware without Secure Boot/TPM enforcement. The
built ISO is **~5.5 GB**, down from the ~7.9 GB official source.

---

## Why this is a separate project from the sibling Win11-Install repo

That project debloats and locks down privacy on a normal, fully-featured
Windows 11 install via live registry/service tweaks after the fact. This
project goes further and removes content from the install image itself
before it's ever installed, to get the on-disk footprint down — a
different technique with different risks, so it lives in its own repo
rather than as a mode of the other one.

## How the debloating is split, and why

Two different mechanisms do the work here, because they have very
different reliability characteristics:

- **`slim-image.ps1`** — offline DISM servicing against `install.wim`
  during the build, before this ISO exists. Everything DISM can safely
  and supportedly do to an unmounted image: drops to a single edition
  index, removes provisioned Appx bloat, removes Windows Capabilities
  (language/font/legacy add-ons), disables Optional Features, bakes in
  .NET Framework 3.5 (needed because Windows Update — the normal on-demand
  fetch mechanism for it — is disabled), runs `/ResetBase` component
  cleanup, then recompresses `install.wim` to `install.esd` (LZMS).
  Microsoft **Edge is also removed here, offline**, the reliable way — its
  installed folders (`Edge` / `EdgeCore` / `EdgeUpdate`) are deleted straight
  out of the mounted image (the tiny11builder approach) and EdgeUpdate is
  blocked from reinstalling it in the registry. WebView2 is kept.
- **`first-boot-tweaks.ps1`** — runs once at first login on the installed
  machine, for the few things that aren't safely doable offline: OneDrive
  removal (a per-user Win32 install whose official uninstaller is more
  complete than offline folder deletion), a runtime Edge **guard** (disable
  EdgeUpdate tasks/services + reassert the reinstall block; Edge itself is
  already gone from the offline image), disabling Windows Update, a broad
  **telemetry-off / privacy** pass, footprint-reducing service disables, a
  **performance power plan**, and confirming Windows Defender still works
  (all live service/scheduled-task/registry state, not image content).

## What's included beyond the OS trim

- **Boots straight to desktop, no login screen.** The answer file creates
  one local Administrator account ("Gamer") with a blank password
  (required so unattended Setup doesn't stop and wait at a password
  prompt), and `first-boot-tweaks.ps1` turns on Windows autologon for it.
  Blank password is what makes this safe — Windows restricts blank-
  password accounts to console/physical logon only, never network. Set a
  real password later via Settings if you want one; autologon simply stops
  working at that point (expected, not a bug).
- **Steam, boots straight into Big Picture — explorer stays the real shell.**
  `first-boot-tweaks.ps1` installs Steam (winget, falling back to the official
  installer), then sets up `Start-GameMode.ps1` as a **per-user Startup item**
  that launches Big Picture on top of the normal desktop behind a black boot
  splash. `explorer.exe` remains the registered `Winlogon\Shell`, so Windows
  starts the desktop (wallpaper + taskbar) the normal, fully-painted way.
  Combined with autologon, the machine goes power-on straight to Steam Big
  Picture, SteamOS/Deck-style; Big Picture's "Exit to Desktop" drops to a
  real, working desktop (no black screen), and a **"Game Mode" desktop icon**
  jumps back into Big Picture at any time.

  This deliberately does **not** replace the shell. An earlier version of this
  project made powershell the `Winlogon\Shell` and hand-launched explorer;
  testing proved that explorer, started as a child process, never takes the
  desktop shell role after Big Picture's fullscreen released — you got a bare
  File Explorer window with no wallpaper/taskbar (a black desktop). Keeping
  explorer as the real shell removes that entire bug class. Mature launcher-
  shell projects reached the same conclusion independently — quangmach/
  GameLauncherShell dropped explorer shell-replacement in its 2.0 rewrite, and
  caffeinateddragonware/windowshandheldmod layers the launcher over a live
  shell — which is also how Xbox's handheld "full screen experience" behaves.
- **Telemetry-off / privacy, footprint reduction, performance power plan, and
  gaming tweaks** — data lifted from Winhance (memstechtips/Winhance), AtlasOS
  (Atlas-OS/Atlas) and winutil (ChrisTitusTech/winutil): telemetry services
  (`DiagTrack`, `dmwappushservice`, `PcaSvc`, `WerSvc`, …) and CEIP/diagnostic
  scheduled tasks disabled; a broad privacy registry pass (`AllowTelemetry=0`,
  EventTranscript + Diagtrack autologger off, advertising ID, activity feed,
  location, Windows Error Reporting, input/speech personalization, Copilot/
  Recall); extra non-gaming services disabled to cut process count (Superfetch,
  Spooler, Connected Devices, Maps, Geolocation, Biometric, NFC/SmartCard, …);
  an **Ultimate/High Performance power plan** with never-sleep + USB selective
  suspend off; plus `Win32PrioritySeparation`, HAGS, Game Mode, and Game DVR/
  overlay tweaks. Applied by `first-boot-tweaks.ps1`, live.

## What this deliberately does NOT do

- **Disk partitioning is left interactive**, same reasoning as the sibling
  project: this answer file doesn't know your target machine's disk
  layout, and scripting that step blind risks wiping the wrong drive.
  Every other OOBE step is unattended; Setup still stops and asks which
  disk to install to.
- **No `-Undo` mode on `first-boot-tweaks.ps1`.** This is a one-shot script
  for a purpose-built image, not a reversible tool. To bring Edge/OneDrive
  back: official installers, see the script's own log output for links. To
  re-enable Windows Update: remove the `NoAutoUpdate` policy value and
  re-enable `wuauserv`/`UsoSvc`.

---

## Install & build

Windows only. Needs **Administrator** (the slimming stage uses
`Mount-WindowsImage`/DISM), about **40 GB free scratch space**, and
**1.5–2.5 hours** — dominated by the `/ResetBase` cleanup and the final
WIM→ESD compression (both CPU-bound). Every command below is in its own block
so it can be copied with one click.

### 1. Get the code

With git:

```powershell
git clone https://github.com/DGBrown21/win11-minimal-gaming.git
cd win11-minimal-gaming
```

No git? Download the ZIP from the repo's green **Code ▾ → Download ZIP**, extract
it, then `cd` into the folder.

### 2. Install the one build prerequisite (Windows ADK Deployment Tools)

Provides `oscdimg.exe`. One-time:

```powershell
winget install --id Microsoft.WindowsADK -e --accept-package-agreements --accept-source-agreements
```

(Or install it manually — you only need the **Deployment Tools** feature:
<https://learn.microsoft.com/windows-hardware/get-started/adk-install>.)

### 3. Build the ISO

Open an **elevated** PowerShell (Terminal/PowerShell "Run as administrator"), then:

```powershell
.\build-windows.ps1
```

It downloads the official Windows 11 ISO from Microsoft, slims it, and writes
`Win11-Minimal.iso` in the repo folder. Move it wherever you like:

```powershell
Move-Item .\Win11-Minimal.iso $env:USERPROFILE\Downloads\
```

### 4. Boot-test in a VM before touching any real hardware

Windows 11 Pro already includes Hyper-V — enable it (elevated), then reboot:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
```

Create a **Generation 2** VM (matches real UEFI boot), 4 GB+ RAM, attach
`Win11-Minimal.iso`, and boot through the full unattended flow. Check:

- OOBE runs unattended up to the disk-selection screen, completes cleanly
  after a disk is picked.
- Boots straight to desktop on the local account via autologon, no login
  screen, then Steam Big Picture launches automatically.
- `install.esd` was actually readable by Setup (this is the one claim in this
  project that's "should work" rather than independently proven elsewhere —
  the VM test is where it gets confirmed).
- Windows Security shows Defender "protected"; `Get-Service WinDefend` →
  `Running`.
- Windows Update shows as disabled.
- `Get-WindowsOptionalFeature -Online -FeatureName NetFx3` shows `Enabled`
  (confirms it was baked in correctly, since WU can't fetch it on demand here).

### 5. Flash to real hardware (only after the VM test passes)

Flash to USB in **"burn ISO as an image"** mode (not "extract files") and
install. Real-hardware validation (actual GPU driver behavior, game installs,
controller/peripheral support) is something only a physical install can prove —
the VM test can't validate that, only that servicing didn't break the base
boot/PnP subsystem.

---

## Files

| File | Purpose |
|---|---|
| `build-windows.ps1` | Fetches the official Microsoft ISO, extracts it, runs `slim-image.ps1`, injects the answer file + first-boot script, rebuilds with `oscdimg`. |
| `slim-image.ps1` | The core size-reduction work — offline DISM servicing against `install.wim`. Can be re-run standalone against an already-extracted `build\extracted` folder while iterating, without re-downloading the source ISO. |
| `autounattend.xml` | The unattended answer file. |
| `first-boot-tweaks.ps1` | OneDrive removal + Edge runtime guard, Windows Update disable, telemetry-off/privacy pass, footprint service disables, performance power plan, Defender safety net, Steam install + Big Picture autostart — runs once at first login. |
| `Start-GameMode.ps1` | Per-user Startup launcher: shows a black splash and launches Steam Big Picture on top of the normal desktop (explorer.exe stays the shell). Staged onto the ISO by `build-windows.ps1`, wired up by `first-boot-tweaks.ps1`. |
| `Win11-Minimal.iso` | **Not in this repo** — build artifact, see `.gitignore`. Build it yourself; redistributing Microsoft's install media isn't something this repo does. |

## Requirements to build

Just the free [Windows ADK "Deployment Tools"](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
feature, for `oscdimg.exe`. `curl`/PowerShell/DISM are already built into
Windows 10/11 — no WSL, no bash, no extra downloads beyond that one ADK
feature. Must run elevated.

## Troubleshooting

If `slim-image.ps1` is killed uncleanly mid-run (Ctrl+C, crash, power
loss), it can leave an orphaned WIM mount behind. The script's own
pre-flight step clears this automatically on the next run, but if you hit
a "path already mounted" error before that, run manually first:
```powershell
dism /Cleanup-Mountpoints
```

Because `explorer.exe` stays the real shell, there's no black-desktop failure
mode to recover from here — if Big Picture ever fails to launch, you're simply
left on the normal desktop and can start Steam manually. To stop the
boot-into-Big-Picture behaviour entirely, delete the **"Game Mode"** shortcut
from the Startup folder:
```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\Startup\Game Mode.lnk
```
The desktop **"Game Mode"** icon re-enters Big Picture on demand at any time.
