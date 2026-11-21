@echo off
:: One-click install of this mpv setup with FastStream for Firefox
:: (installer\setup.ps1): no admin rights, no git, no Node.js installation.
:: mpv goes to %LOCALAPPDATA%\Programs\mpv; README.md, "Install", says more.
:: In a downloaded copy of the repository the setup next to this file runs;
:: on its own, this file fetches the setup from GitHub into %TEMP% and runs
:: it as a file there.
::
:: Run from an installed folder, the setup can replace THIS file, and cmd reads
:: a batch file line by line, by byte offset (see updater.bat): everything from
:: the setup on is ONE block, and a failure goes to the label :failed.
setlocal
set "fetched=%TEMP%\mpv-config-setup-%RANDOM%%RANDOM%"
(
    if exist "%~dp0installer\setup.ps1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\setup.ps1" %*
    ) else (
        powershell -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference = 'Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; $null = New-Item -ItemType Directory -Force -Path $env:fetched; Invoke-WebRequest -UseBasicParsing https://raw.githubusercontent.com/Nawid3333/mpv-config/main/installer/setup.ps1 -OutFile (Join-Path $env:fetched 'setup.ps1')" && powershell -NoProfile -ExecutionPolicy Bypass -File "%fetched%\setup.ps1" %*
    )
    if errorlevel 1 goto failed
    if exist "%fetched%\" rd /s /q "%fetched%"
    echo.
    pause
    exit /b 0
)
:: keep this label in every version (see updater.bat)
:failed
if exist "%fetched%\" rd /s /q "%fetched%"
echo.
pause
exit /b 1
