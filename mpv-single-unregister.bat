@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-single-unregister.ps1"
if %errorlevel% neq 0 (
    echo Deregistration failed.
    pause
    exit /b %errorlevel%
)

pause
endlocal
