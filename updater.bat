@echo off
:: Brings this mpv folder up to date (installer\update.ps1): git pull - the code,
:: and mpv-build.json, which CI moves to each new mpv build that passes the
:: regression tests - then installs exactly that build and updates yt-dlp.
:: mpv's own files are not kept in git (2026-10-03), so an update never leaves
:: anything to commit. Until then this was shinchiro's updater.bat.
::
:: The update can replace THIS file (git pull, or sync-config in a one-click
:: install), and cmd reads a batch file line by line, by byte offset: after the
:: update it would go on in the new file at the old offset (measured 2026-10-12:
:: it ran pieces of lines as commands, and the update again, in a loop). So
:: everything from the update on is ONE block, which cmd reads whole first.
setlocal
cd /d "%~dp0"
set "ps=powershell"
where pwsh >nul 2>nul && set "ps=pwsh"
(
    %ps% -NoProfile -NoLogo -ExecutionPolicy Bypass -File "%~dp0installer\update.ps1"
    if errorlevel 1 goto failed
    echo.
    pause
    exit /b 0
)
:: A failed update, by label: cmd finds a label by its text, in a file the update
:: replaced too (keep this label in every version), and an "exit /b 1" inside the
:: block above came out as exit code 0 from "cmd /c" (measured 2026-10-12).
:failed
echo.
pause
exit /b 1
