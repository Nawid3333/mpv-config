@echo off
:: One-click install of this mpv setup with FastStream for Firefox
:: (installer\setup.ps1): no admin rights, no git, no Node.js installation.
:: mpv goes to %LOCALAPPDATA%\Programs\mpv; README.md, "Install", says more.
:: In a downloaded copy of the repository the setup next to this file runs;
:: on its own, this file fetches the setup from GitHub.
setlocal
if exist "%~dp0installer\setup.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\setup.ps1" %*
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing https://raw.githubusercontent.com/Nawid3333/mpv-config/main/installer/setup.ps1))) %*"
)
set rc=%errorlevel%
echo.
pause
exit /b %rc%
