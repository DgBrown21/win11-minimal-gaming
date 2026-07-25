# Windows 11 Pro — Minimal Gaming Build

Builds a heavily size-reduced Windows 11 Pro install ISO aimed purely at
PC gaming: local account only, no Microsoft Account, no Edge, no OneDrive,
no bundled apps/features beyond what a gaming box needs, Windows Defender
kept working, Windows Update disabled. Built for bare-metal installs on
hardware without Secure Boot/TPM enforcement.

## License

Licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE) — free
to use, modify, and share for any noncommercial purpose.

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
- **`first-boot-tweaks.ps1`** — runs once at first login on the installed
  machine, for the few things that aren't safely doable offline: Microsoft
  Edge removal and OneDrive removal (both are Win32 installs baked in via
  their own installer, not provisioned Appx packages — offline DISM
  removal of either from a retail image is unsupported/unreliable), plus
  disabling Windows Update and confirming Windows Defender still works
  (both are live service/scheduled-task state, not image content).

## Honest size expectations

**The target is ~3GB, down from a stock ~8.4GB ISO — treat this as a
stretch goal, not a guarantee.** Aggressive component removal (single-
index export + Appx/capability/feature strip + `/ResetBase`) combined with
ESD/LZMS recompression on a full Windows 11 Pro image realistically lands
somewhere in the **3.5-4.5GB range** for a build like this one, which
deliberately keeps Windows Defender working, keeps gaming-relevant
Xbox/runtime components installed, and skips driver-package pruning (all
of which cost some of the size more aggressive "core-only" builds save
elsewhere). If the first build lands at 4GB instead of 3GB, that's the
expected outcome, not a bug — going further (driver pruning, stricter
language stripping) is possible in a later pass if needed.

## What's included beyond the OS trim

- **Boots straight to desktop, no login screen.** The answer file creates
  one local Administrator account ("Gamer") with a blank password
  (required so unattended Setup doesn't stop and wait at a password
  prompt), and `first-boot-tweaks.ps1` turns on Windows autologon for it.
  Blank password is what makes this safe — Windows restricts blank-
  password accounts to console/physical logon only, never network. Set a
  real password later via Settings if you want one; autologon simply stops
  working at that point (expected, not a bug).
- **Steam, installed and boots straight into Big Picture via a Game Mode
  shell** — `first-boot-tweaks.ps1` installs Steam (winget, falling back to
  the official installer), then registers `game-mode-shell.ps1` as the
  Windows shell (`Winlogon\Shell`, in place of `explorer.exe`) instead of
  just autostarting Big Picture on top of a normal desktop. The shell
  script launches `explorer.exe` itself first (so a real desktop still
  exists underneath) and then Big Picture on top — combined with autologon
  above, the machine goes power-on straight to Steam Big Picture, SteamOS/
  Deck-style. Big Picture's own "Exit to Desktop" reveals the desktop
  that's already running; a **"Game Mode" icon on the desktop** jumps back
  into Big Picture at any time. See `game-mode-shell.ps1`'s header for the
  full mechanism and the Safe Mode recovery command if this ever needs
  reverting on an already-imaged machine.
- **Telemetry services/tasks and gaming performance tweaks** — data lifted
  from Winhance (memstechtips/Winhance) and AtlasOS (Atlas-OS/Atlas): the
  usual telemetry services (`DiagTrack`, `dmwappushservice`, `PcaSvc`, etc.)
  and CEIP/diagnostic scheduled tasks disabled, plus `Win32PrioritySeparation`,
  HAGS, Game Mode, and Game DVR/overlay tweaks. Applied by
  `first-boot-tweaks.ps1`, live, alongside the WU/Edge/OneDrive work it
  already did.

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

## Quick start

1. **Build the ISO** (Windows only for now — needs the free [Windows ADK
   "Deployment Tools" feature](https://learn.microsoft.com/windows-hardware/get-started/adk-install)
   for `oscdimg.exe`, and must run as **Administrator** since the
   slimming stage needs `Mount-WindowsImage`/DISM):
   ```powershell
   .\build-windows.ps1
   ```
   Needs roughly **40GB free scratch space** and **1.5-2.5 hours**,
   dominated by the `/ResetBase` component cleanup and the final WIM→ESD
   compression pass (both CPU-bound). Produces `Win11-Minimal.iso`.

2. **Boot-test in a VM before touching any real hardware.** Windows 11 Pro
   already includes Hyper-V:
   ```powershell
   Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All
   ```
   Create a **Generation 2** VM (matches real UEFI boot), 4GB+ RAM, attach
   `Win11-Minimal.iso`, and boot through the full unattended flow. Check:
   - OOBE runs unattended up to the disk-selection screen, completes
     cleanly after a disk is picked.
   - Boots straight to desktop on the local account via autologon, no login
     screen, then Steam Big Picture launches automatically.
   - `install.esd` was actually readable by Setup (this is the one claim
     in this project that's "should work" rather than independently
     proven elsewhere — the VM test is where it gets confirmed).
   - Windows Security shows Defender "protected"; `Get-Service WinDefend`
     → `Running`.
   - Windows Update shows as disabled.
   - `Get-WindowsOptionalFeature -Online -FeatureName NetFx3` shows
     `Enabled` (confirms it was baked in correctly, since WU can't fetch
     it on demand here).

3. **Only after the VM test passes cleanly**, flash to USB ("burn ISO as
   an image" mode, not "extract files") and install on real hardware.
   Real-hardware validation (actual GPU driver behavior, game installs,
   controller/peripheral support) is something only a physical install can
   prove — the VM test can't validate that, only that servicing didn't
   break the base boot/PnP subsystem.

---

## Files

| File | Purpose |
|---|---|
| `build-windows.ps1` | Fetches the official Microsoft ISO, extracts it, runs `slim-image.ps1`, injects the answer file + first-boot script, rebuilds with `oscdimg`. |
| `slim-image.ps1` | The core size-reduction work — offline DISM servicing against `install.wim`. Can be re-run standalone against an already-extracted `build\extracted` folder while iterating, without re-downloading the source ISO. |
| `autounattend.xml` | The unattended answer file. |
| `first-boot-tweaks.ps1` | Edge/OneDrive removal, Windows Update disable, Defender safety net, telemetry/gaming-perf tweaks, Game Mode shell setup — runs once at first login. |
| `game-mode-shell.ps1` | Registered as the Windows shell in place of `explorer.exe` — boots straight into Steam Big Picture, SteamOS/Deck-style. Staged onto the ISO by `build-windows.ps1`, installed by `first-boot-tweaks.ps1`. |
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

If the **Game Mode shell** ever fails to reach a usable desktop on an
already-imaged machine (a bad edit to `game-mode-shell.ps1`, Steam moved,
etc.), boot to Safe Mode / Safe Mode with Command Prompt and run:
```
reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v Shell /t REG_SZ /d explorer.exe /f
```
then reboot normally — this reverts to a plain `explorer.exe` desktop with
no Big Picture autostart; Steam can still be launched manually from there.
