@echo off
:: Brings this mpv folder up to date (installer\update.ps1): git pull - the code,
:: and mpv-build.json, which CI moves to each new mpv build that passes the
:: regression tests - then installs exactly that build and updates yt-dlp.
:: mpv's own files are not kept in git (2026-10-03), so an update never leaves
:: anything to commit. Until then this was shinchiro's updater.bat.
setlocal
cd /d "%~dp0"
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0installer\update.ps1"
) else (
    powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0installer\update.ps1"
)
set rc=%errorlevel%
echo.
pause
exit /b %rc%
