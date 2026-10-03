@echo off
setlocal

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0mpv-single-register.ps1"
if %errorlevel% neq 0 (
    echo Registration failed.
    pause
    exit /b %errorlevel%
)

pause
endlocal
