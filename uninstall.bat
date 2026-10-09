@echo off
:: Removes this mpv (installer\uninstall.ps1): the "Open with" entries, the
:: Start menu folder, the FastStream helper the setup installed for it, and
:: this folder with everything in it. Only for a folder the one-click install
:: (install.bat) made; a git clone is refused.
:: The folder is deleted a few seconds after this ends (this file is in it),
:: so everything after the uninstall runs from ONE line: cmd reads a batch
:: file line by line and would not find the next one.
setlocal
cd /d "%TEMP%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0installer\uninstall.ps1" & echo. & pause & exit /b
