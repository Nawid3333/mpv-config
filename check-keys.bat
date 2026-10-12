@echo off
:: Which keys does each running mpv use? A read-only check for when mpv seems to
:: ignore this setup's keys (installer\check-keys.ps1): run it while that mpv is open.
setlocal
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0installer\check-keys.ps1"
) else (
    powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0installer\check-keys.ps1"
)
echo.
pause
