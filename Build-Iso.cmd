@echo off
REM Double-click this to build Win11-Minimal.iso into your Downloads folder.
REM It hands off to Build-Iso.ps1, which self-elevates (UAC), installs the
REM Windows ADK if needed, and runs the build. Passes any extra args through
REM (e.g. Build-Iso.cmd -SkipDownload).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Iso.ps1" %*
