<#
.SYNOPSIS
    One-click install of this mpv setup, with FastStream for Firefox.

.DESCRIPTION
    For a new PC (2026-10-09). No admin rights, no git, no Node.js
    installation, nothing changed for the whole PC. Run it in PowerShell:

        irm https://raw.githubusercontent.com/Nawid3333/mpv-config/main/installer/setup.ps1 | iex

    or double-click install.bat in a downloaded copy of the repository.

      1. checks the PC: 64-bit Windows 10 or 11, a Vulkan graphics driver,
         a CPU with AVX2 (the mpv build needs it; proven by starting mpv once
         after the install);
      2. installs the config into %LOCALAPPDATA%\Programs\mpv (another folder
         with -InstallDir): GitHub's ZIP of the newest commit, Git LFS files
         fetched and checked (installer\sync-config.ps1);
      3. installs mpv itself (the build mpv-build.json pins, every file
         checked by SHA-256) and yt-dlp (installer\update.ps1);
      4. FastStream: the mpv helper for Firefox with a private Node.js, and
         the FastStream add-on opened in Firefox for one click
         (installer\install-faststream.ps1; skip with -NoFastStream);
      5. "Open with" entries for video and audio files (mpv --register, for
         this Windows user only; skip with -NoFileTypes) - unless another mpv
         is registered already, which keeps them - and a Start menu
         folder "mpv" with mpv, "Update mpv" and "Uninstall mpv"
         (skip with -NoShortcuts).

    Run it again to repair or update; updater.bat (Start menu: Update mpv)
    updates everything later. uninstall.bat removes it.

    Arguments through the one-liner:
        & ([scriptblock]::Create((irm <url>))) -InstallDir D:\mpv -NoFastStream

.PARAMETER InstallDir
    Where mpv goes. Default: %LOCALAPPDATA%\Programs\mpv. A new or empty
    folder, or one this setup installed before.

.PARAMETER Yes
    Ask nothing (a FastStream helper someone else installed is then kept).

.PARAMETER Zip
    Test use: install the config from this ZIP (needs -Commit) with the
    sync-config.ps1 next to this script.

.PARAMETER NoMpv
    Test use: skip mpv, yt-dlp and the check that mpv starts.

.PARAMETER AppPathsKeys
    Test use: where a registration records which mpv it registered (this
    user's, and the whole PC's, which an admin install like mpv-install.bat makes).
#>
[CmdletBinding()]
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'Programs\mpv'),
    [string]$Repo = 'Nawid3333/mpv-config',
    [string]$Ref = 'main',
    [switch]$NoFastStream,
    [switch]$NoFileTypes,
    [switch]$NoShortcuts,
    [switch]$Yes,
    [string]$Zip,
    [string]$Commit,
    [string]$LfsSource,
    [switch]$NoMpv,
    [string[]]$AppPathsKeys = @('HKCU:\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe',
        'HKLM:\Software\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe')
)

# Everything runs inside this function: through "irm | iex" the script runs in the
# caller's own session, where a top-level exit would close their PowerShell window
# and a top-level $ErrorActionPreference would stay set after it.
function Invoke-MpvSetup {
    param(
        [string]$InstallDir, [string]$Repo, [string]$Ref, [switch]$NoFastStream, [switch]$NoFileTypes,
        [switch]$NoShortcuts, [switch]$Yes, [string]$Zip, [string]$Commit, [string]$LfsSource, [switch]$NoMpv,
        [string[]]$AppPathsKeys
    )
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ps = (Get-Process -Id $PID).Path

    function Step([string]$Text) { Write-Host "`n== $Text" -ForegroundColor Cyan }
    # A child process on this console: its coloured lines go straight to the screen
    # (output of "& ..." inside a function would become this function's return value).
    function Invoke-Child([string]$Script, [string[]]$Arguments) {
        $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Script) + $Arguments
        # Start-Process joins the arguments with spaces: quote each (paths can hold spaces)
        $line = ($all | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
        $p = Start-Process -FilePath $ps -ArgumentList $line -NoNewWindow -Wait -PassThru
        return $p.ExitCode
    }

    Write-Host 'mpv for Windows (anime and film) + FastStream - setup' -ForegroundColor White
    Write-Host "Folder: $InstallDir  (no admin rights needed)"

    # -- 1. the PC ----------------------------------------------------------------------
    Step 'Checking this PC'
    if (-not [Environment]::Is64BitOperatingSystem -or [Environment]::OSVersion.Version.Major -lt 10) {
        Write-Host 'This needs 64-bit Windows 10 or 11.' -ForegroundColor Red
        return 1
    }
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        Write-Host 'Running as administrator is not needed. Everything is set up for the Windows account that runs this.' -ForegroundColor Yellow
    }
    if (-not (Test-Path -LiteralPath (Join-Path $env:WINDIR 'System32\vulkan-1.dll'))) {
        Write-Host 'No Vulkan driver found (vulkan-1.dll). mpv draws the video with Vulkan: install the newest driver for your graphics card from AMD, NVIDIA or Intel.' -ForegroundColor Yellow
    }
    try {
        if (-not ('MpvSetup.Cpu' -as [type])) {
            Add-Type -Namespace MpvSetup -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
        }
        # PF_AVX2_INSTRUCTIONS_AVAILABLE; an older Windows may not know the flag, so this only warns
        if (-not [MpvSetup.Cpu]::IsProcessorFeaturePresent(40)) {
            Write-Host 'Windows does not report AVX2 for this CPU. The mpv build needs it (Intel from 2013, AMD from 2015); it is tested after the install.' -ForegroundColor Yellow
        }
    }
    catch { Write-Verbose "AVX2 check: $_" }

    # -- 2. the config ------------------------------------------------------------------
    $dir = [IO.Path]::GetFullPath($InstallDir)
    if (Test-Path -LiteralPath $dir) {
        if (Test-Path -LiteralPath (Join-Path $dir '.git')) {
            Write-Host "$dir is a git clone of this config - update it with its updater.bat instead." -ForegroundColor Red
            return 1
        }
        if (Test-Path -LiteralPath (Join-Path $dir '.install-manifest.json')) {
            Write-Host 'Found an earlier install here: updating and repairing it.'
        }
        elseif (Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1) {
            Write-Host "$dir is not empty. Choose a new or empty folder: -InstallDir <folder>" -ForegroundColor Red
            return 1
        }
    }
    Step 'Config (scripts, shaders, settings)'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('mpv-setup-' + [guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $tmp
    try {
        $syncArgs = @('-Root', $dir, '-Repo', $Repo, '-Ref', $Ref)
        if ($Zip) {
            if (-not $PSScriptRoot) { throw '-Zip needs a local copy of this script' }
            $sync = Join-Path $PSScriptRoot 'sync-config.ps1'
            $syncArgs += @('-Zip', $Zip, '-Commit', $Commit)
            if ($LfsSource) { $syncArgs += @('-LfsSource', $LfsSource) }
        }
        else {
            # the sync script of exactly the commit that gets installed
            try {
                $Commit = "$(Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/commits/$Ref" -UseBasicParsing -TimeoutSec 60 `
                    -Headers @{ Accept = 'application/vnd.github.sha'; 'User-Agent' = 'mpv-config-installer' })".Trim()
                $sync = Join-Path $tmp 'sync-config.ps1'
                Invoke-WebRequest -Uri "https://raw.githubusercontent.com/$Repo/$Commit/installer/sync-config.ps1" -OutFile $sync -UseBasicParsing -TimeoutSec 60
            }
            catch {
                Write-Host "Could not reach GitHub: $($_.Exception.Message)" -ForegroundColor Red
                return 2
            }
            $syncArgs += @('-Commit', $Commit)
        }
        $rc = Invoke-Child $sync $syncArgs
        if ($rc -ne 0) { Write-Host 'The config could not be installed (see above).' -ForegroundColor Red; return $rc }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # -- 3. mpv and yt-dlp ------------------------------------------------------------------
    $mpvExe = Join-Path $dir 'mpv.exe'
    if (-not $NoMpv) {
        Step 'mpv and yt-dlp'
        $rc = Invoke-Child (Join-Path $dir 'installer\update.ps1') @('-Root', $dir, '-NoFastStream')
        if ($rc -ne 0) { Write-Host 'mpv or yt-dlp could not be installed (see above). Run the setup again to retry.' -ForegroundColor Red; return 1 }
        # the build is made for CPUs with AVX2: on others mpv dies at its first instruction
        $out = & (Join-Path $dir 'mpv.com') --no-config --version 2>&1
        $code = $LASTEXITCODE
        if ($code -eq -1073741795) {
            Write-Host 'mpv cannot run on this CPU: it has no AVX2 (Intel before 2013, AMD before 2015, some Celeron/Pentium/Atom). This setup uses mpv builds that need it.' -ForegroundColor Red
            return 1
        }
        if ($code -ne 0) { Write-Host "mpv does not start (exit $code): $($out | Select-Object -First 3)" -ForegroundColor Red; return 1 }
        Write-Host "mpv runs: $(@($out)[0])" -ForegroundColor Green
    }

    # -- 4. FastStream ----------------------------------------------------------------------------
    $fsNote = $false
    if (-not $NoFastStream) {
        Step 'FastStream (Firefox add-on + mpv helper)'
        $fsArgs = @('-MpvExe', $mpvExe)
        if ($Yes) { $fsArgs += '-Yes' }
        $rc = Invoke-Child (Join-Path $dir 'installer\install-faststream.ps1') $fsArgs
        if ($rc -ne 0) { Write-Host 'FastStream could not be set up (see above). mpv itself is installed; run the setup again to retry.' -ForegroundColor Yellow }
        else { $fsNote = $true }
    }

    # -- 5. Windows integration ---------------------------------------------------------------------
    # mpv --register writes per-user entries every mpv shares (App Paths\mpv.exe, the
    # io.mpv.* file types), and this user's would hide a registration for the whole PC
    # (2026-10-09: the owner's mpv in Program Files, registered machine-wide by an admin
    # install): another mpv that is registered and still there keeps them.
    $registered = $null
    if (-not $NoFileTypes) {
        foreach ($key in $AppPathsKeys) {
            $p = Get-ItemPropertyValue -ErrorAction SilentlyContinue $key '(default)'
            if ($p -and $p -ne $mpvExe -and (Test-Path -LiteralPath $p)) { $registered = $p; break }
        }
    }
    if ($registered) {
        Step '"Open with" entries for video and audio files'
        Write-Host "Another mpv is registered for Open with ($registered): left as it is." -ForegroundColor Yellow
        Write-Host "  To offer this one instead: $(Join-Path $dir 'mpv-register.bat')" -ForegroundColor Yellow
    }
    elseif (-not $NoFileTypes -and (Test-Path -LiteralPath (Join-Path $dir 'mpv.com'))) {
        Step '"Open with" entries for video and audio files'
        $null = & (Join-Path $dir 'mpv.com') --no-config --register 2>&1
        if ($LASTEXITCODE -eq 0) { Write-Host 'mpv is offered for video and audio files (Open with). Your default player is not changed.' -ForegroundColor Green }
        else { Write-Host "mpv --register failed (exit $LASTEXITCODE); mpv itself works." -ForegroundColor Yellow }
    }
    if (-not $NoShortcuts) {
        Step 'Start menu'
        $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'mpv'
        $null = New-Item -ItemType Directory -Force -Path $menu
        $shell = New-Object -ComObject WScript.Shell
        foreach ($s in @(
                @{ Name = 'mpv'; Target = $mpvExe; Icon = $mpvExe },
                @{ Name = 'Update mpv'; Target = (Join-Path $dir 'updater.bat'); Icon = $mpvExe },
                @{ Name = 'Uninstall mpv'; Target = (Join-Path $dir 'uninstall.bat'); Icon = $mpvExe })) {
            $lnk = $shell.CreateShortcut((Join-Path $menu "$($s.Name).lnk"))
            $lnk.TargetPath = $s.Target
            $lnk.WorkingDirectory = $dir
            if (Test-Path -LiteralPath $s.Icon) { $lnk.IconLocation = "$($s.Icon),0" }
            $lnk.Save()
        }
        Write-Host "Start menu > mpv: mpv, Update mpv, Uninstall mpv." -ForegroundColor Green
    }

    Write-Host "`nDone. mpv is in $dir" -ForegroundColor Green
    Write-Host '  - Open a video with mpv (right-click > Open with), or start mpv from the Start menu.'
    Write-Host '    The first video compiles the upscaling shaders in the background (a small banner top right).'
    Write-Host '  - Right-click in mpv opens the menu with everything; Shift+A / Shift+Y switch Anime / Movie upscaling.'
    if ($fsNote) {
        Write-Host '  - FastStream: after adding it in Firefox, RESTART Firefox. Then in FastStream''s settings > MPV Mode,'
        Write-Host '    tick "Open detected streams in mpv" and add your video sites to the MPV Allowlist'
        Write-Host '    (one per line; put @anime after anime sites, e.g. https://anime.example.org @anime).'
    }
    Write-Host '  - Updates: Start menu > mpv > Update mpv.'
    return 0
}

$code = Invoke-MpvSetup -InstallDir $InstallDir -Repo $Repo -Ref $Ref -NoFastStream:$NoFastStream -NoFileTypes:$NoFileTypes `
    -NoShortcuts:$NoShortcuts -Yes:$Yes -Zip $Zip -Commit $Commit -LfsSource $LfsSource -NoMpv:$NoMpv -AppPathsKeys $AppPathsKeys
# Run as a file (install.bat) it hands its exit code on. Through "irm | iex" it must not
# exit: $PSCommandPath is then empty, or - iex inside someone's own script - that script.
if ($PSCommandPath -and (Split-Path -Leaf $PSCommandPath) -eq 'setup.ps1') { exit $code }
