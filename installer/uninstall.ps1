<#
.SYNOPSIS
    Removes an mpv the one-click install (installer\setup.ps1) set up.

.DESCRIPTION
    uninstall.bat (Start menu: Uninstall mpv) runs this (2026-10-09):

      1. the "Open with" entries (mpv --unregister), if they are this mpv's -
         every mpv shares them, and another one registered keeps them;
      2. the Start menu folder "mpv", if its shortcut starts this mpv;
      3. the FastStream helper, if the setup installed it for this mpv
         (%LOCALAPPDATA%\FastStreamMpvHost and its HKCU registry key) - a
         helper someone installed by hand is left alone;
      4. the folder itself, with your settings, watch history and saved
         positions in it (removed a moment after this script ends, because
         uninstall.bat runs from inside it).

    The FastStream add-on stays in Firefox: remove it in about:addons if you
    no longer want it. A git clone of this config is refused: delete that by
    hand. Works in Windows PowerShell 5.1 and PowerShell 7.

.PARAMETER Root
    The installed folder. Default: the folder this script sits in.

.PARAMETER Yes
    Do not ask before removing.

.PARAMETER KeepFolder
    Test use: do everything except deleting the folder.

.PARAMETER HelperDir
    Test use: where the FastStream helper is. Default: %LOCALAPPDATA%\FastStreamMpvHost.

.PARAMETER NoFileTypes
    Test use: leave the "Open with" entries alone.

.PARAMETER AppPathsKey
    Test use: where mpv --register records which mpv it registered.
#>
[CmdletBinding()]
param(
    [string]$Root = (Split-Path $PSScriptRoot -Parent),
    [switch]$Yes,
    [switch]$KeepFolder,
    [string]$HelperDir = (Join-Path $env:LOCALAPPDATA 'FastStreamMpvHost'),
    [switch]$NoFileTypes,
    [string]$AppPathsKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe'
)

$ErrorActionPreference = 'Stop'

# A native program's output, stderr included. Windows PowerShell 5.1 turns every stderr
# line into a terminating error under 'Stop' once 2>&1 redirects it (checked
# 2026-10-09: a single warning from mpv, 7-Zip or FastStream's install.ps1 ended the
# install); the exit code decides here.
function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    $ErrorActionPreference = 'Continue'
    $out = @(& $Exe @Arguments 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out }
}

try {
    $Root = (Resolve-Path -LiteralPath $Root).Path
    if (Test-Path -LiteralPath (Join-Path $Root '.git')) {
        throw "$Root is a git clone, not a folder the setup installed - delete it by hand if you want it gone"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.install-manifest.json'))) {
        throw "$Root was not installed by the setup (no .install-manifest.json) - nothing removed"
    }
    $mpvExe = Join-Path $Root 'mpv.exe'
    if (-not $Yes) {
        Write-Host "This removes mpv from $Root," -ForegroundColor Yellow
        Write-Host 'with your settings, watch history and saved positions.' -ForegroundColor Yellow
        $a = Read-Host 'Remove it? [y/N]'
        if ($a -notmatch '^(y|yes|j|ja)$') { Write-Host 'Nothing removed.'; exit 0 }
    }
    $running = @(Get-Process mpv -ErrorAction SilentlyContinue | Where-Object {
            # this folder, not one whose name starts the same (D:\mpv-old for D:\mpv)
            $_.Path -and $_.Path.StartsWith($Root.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
        })
    if ($running.Count) { throw 'mpv is still running - close it and run this again' }

    # 1. "Open with" - mpv --unregister removes them whichever mpv registered them
    #    (any mpv can, the manual says): only when they are this mpv's
    if (-not $NoFileTypes) {
        $registered = "$(Get-ItemPropertyValue -ErrorAction SilentlyContinue $AppPathsKey '(default)')".Trim('"')
        if ($registered -and $registered -ne $mpvExe) {
            Write-Host "The Open with entries belong to another mpv ($registered): left as they are."
        }
        elseif ($registered -and (Test-Path -LiteralPath (Join-Path $Root 'mpv.com'))) {
            $r = Invoke-Native (Join-Path $Root 'mpv.com') @('--no-config', '--unregister')
            if ($r.Code -eq 0) { Write-Host '"Open with" entries removed.' }
            else { Write-Host "mpv --unregister failed (exit $($r.Code)): $($r.Out | Select-Object -Last 2)" -ForegroundColor Yellow }
        }
    }

    # 2. the Start menu folder, only if it is this mpv's
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'mpv'
    $lnk = Join-Path $menu 'mpv.lnk'
    if (Test-Path -LiteralPath $lnk) {
        $target = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath
        if ($target -eq $mpvExe) {
            Remove-Item -LiteralPath $menu -Recurse -Force
            Write-Host 'Start menu folder removed.'
        }
    }

    # 3. the FastStream helper the setup installed for this mpv
    $marker = Join-Path $HelperDir 'installed-by-mpv-config.json'
    if (Test-Path -LiteralPath $marker) {
        # UTF-8 without a BOM: read as ANSI, a path with a letter outside ASCII never matched
        $m = try { Get-Content -Raw -Encoding UTF8 -LiteralPath $marker | ConvertFrom-Json } catch { $null }
        if ($m -and "$($m.mpv)" -eq $mpvExe) {
            $key = 'HKCU:\Software\Mozilla\NativeMessagingHosts\com.faststream.mpv'
            $registered = Get-ItemPropertyValue -ErrorAction SilentlyContinue $key '(default)'
            if ($registered -and $registered.StartsWith($HelperDir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) {
                Remove-Item -LiteralPath $key -Recurse -Force
            }
            Remove-Item -LiteralPath $HelperDir -Recurse -Force
            Write-Host 'FastStream helper removed. The FastStream add-on stays in Firefox (about:addons removes it).'
        }
    }

    # 4. the folder: uninstall.bat runs from inside it, so a separate cmd removes it
    #    once this script and the batch file have ended
    if (-not $KeepFolder) {
        Set-Location -LiteralPath ([IO.Path]::GetTempPath())
        $cmdLine = "/d /c ping -n 4 127.0.0.1 >nul & rmdir /s /q `"$Root`""
        Start-Process -FilePath (Join-Path $env:WINDIR 'System32\cmd.exe') -ArgumentList $cmdLine -WindowStyle Hidden
        Write-Host "mpv is removed ($Root goes in a few seconds)." -ForegroundColor Green
    }
    exit 0
}
catch {
    Write-Host "uninstall: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
