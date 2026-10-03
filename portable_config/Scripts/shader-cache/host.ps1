# host.ps1 - runs the shader warm-up (warmup.lua) inside a window that is never
# shown, so it compiles in the background while the video plays. Started by
# main.lua through Windows PowerShell 5.1 (always present on Windows).
#
# Why a window at all: libplacebo compiles a chain only when it draws with it,
# and mpv draws only into a real window. Measured 2026-09-26:
#   --window-minimized   no focus taken, but nothing drawn (0 compiles)
#   a normal 2nd window  takes the keyboard focus from the video
#   hidden, off-screen   draws, but mpv cannot read the monitor there and picks
#                        another output format (17 of ~120 shaders differed)
#   hidden, ON the monitor  draws and matches fullscreen playback (the same
#                        2 run-to-run stragglers as fullscreen vs fullscreen)
# So: a borderless window that is created but never shown, laid exactly over
# the player's monitor, with mpv embedded in it (--wid). When this process
# ends, the window goes and mpv quits by itself (w32_common.c: WM_DESTROY in
# --wid mode -> CLOSE_WIN), so the player ending it leaves nothing behind.
# Belt and braces: mpv also runs in a job object that kills it when this
# process goes, however it goes (the player's quit terminates this process;
# a --vo=null test warm-up has no window to lose).
param(
    # line 1: mpv.exe, then one mpv argument per line (UTF-8)
    [Parameter(Mandatory = $true)][string]$ArgsFile,
    # the player's window (mpv's window-id) - its monitor is the one to match
    [long]$Owner = 0
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace ShaderCache -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(System.IntPtr value);
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool IsWindow(System.IntPtr hwnd);
[DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern System.IntPtr CreateJobObject(System.IntPtr attributes, string name);
[DllImport("kernel32.dll")] public static extern bool SetInformationJobObject(System.IntPtr job, int infoClass, System.IntPtr info, uint length);
[DllImport("kernel32.dll")] public static extern bool AssignProcessToJobObject(System.IntPtr job, System.IntPtr process);
'@

# A job that kills its processes when its last handle closes - i.e. when this
# process exits. JOBOBJECT_EXTENDED_LIMIT_INFORMATION (class 9): 144 bytes on
# 64-bit, 112 on 32-bit; LimitFlags sits at offset 16 in both.
$job = [ShaderCache.Native]::CreateJobObject([IntPtr]::Zero, $null)
if ($job -ne [IntPtr]::Zero) {
    $size = if ([IntPtr]::Size -eq 8) { 144 } else { 112 }
    $info = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($size)
    try {
        for ($i = 0; $i -lt $size; $i++) { [System.Runtime.InteropServices.Marshal]::WriteByte($info, $i, 0) }
        [System.Runtime.InteropServices.Marshal]::WriteInt32($info, 16, 0x2000) # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        [void][ShaderCache.Native]::SetInformationJobObject($job, 9, $info, $size)
    } finally {
        [System.Runtime.InteropServices.Marshal]::FreeHGlobal($info)
    }
}
# Physical pixels: without this, Windows scales a PowerShell window at 125-150 %
# display scaling and mpv would render (and compile) at the wrong size.
if (-not [ShaderCache.Native]::SetProcessDpiAwarenessContext([IntPtr]-4)) {
    # PER_MONITOR_AWARE_V2 needs Windows 10 1703+
    [void][ShaderCache.Native]::SetProcessDPIAware()
}

# Windows command-line quoting (CommandLineToArgvW rules): Windows PowerShell's
# ProcessStartInfo has no ArgumentList.
function ConvertTo-CommandLineArgument([string]$Value) {
    if ($Value -ne '' -and $Value -notmatch '[\s"]') { return $Value }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $slashes = 0
    foreach ($c in $Value.ToCharArray()) {
        if ($c -eq '\') { $slashes++; continue }
        if ($c -eq '"') { [void]$sb.Append('\' * ($slashes * 2 + 1)) } else { [void]$sb.Append('\' * $slashes) }
        [void]$sb.Append($c)
        $slashes = 0
    }
    [void]$sb.Append('\' * ($slashes * 2)).Append('"')
    return $sb.ToString()
}

$lines = [System.IO.File]::ReadAllLines($ArgsFile, [System.Text.Encoding]::UTF8)
$exe = $lines[0]
$mpvArgs = @($lines | Select-Object -Skip 1 | Where-Object { $_ -ne '' })

$screen = if ($Owner -ne 0) { [System.Windows.Forms.Screen]::FromHandle([IntPtr]$Owner) } else { [System.Windows.Forms.Screen]::PrimaryScreen }
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.StartPosition = 'Manual'
$form.Location = $screen.Bounds.Location
$form.ClientSize = $screen.Bounds.Size
$hwnd = $form.Handle.ToInt64() # creates the window; it is never shown

$cmd = (@($mpvArgs) + "--wid=$hwnd" | ForEach-Object { ConvertTo-CommandLineArgument $_ }) -join ' '
$psi = New-Object System.Diagnostics.ProcessStartInfo $exe, $cmd
$psi.UseShellExecute = $false
$psi.RedirectStandardOutput = $true
$p = [System.Diagnostics.Process]::Start($psi)
if ($job -ne [IntPtr]::Zero) { [void][ShaderCache.Native]::AssignProcessToJobObject($job, $p.Handle) }

# Pump this window's messages (mpv's child window sends some to it) and pass
# mpv's RESULT lines on to the player, which reads this process's output.
$read = $p.StandardOutput.ReadLineAsync()
while ($true) {
    [System.Windows.Forms.Application]::DoEvents()
    if ($read.IsCompleted) {
        if ($null -eq $read.Result) { break } # mpv closed its output: it is exiting
        [Console]::Out.WriteLine($read.Result)
        [Console]::Out.Flush()
        $read = $p.StandardOutput.ReadLineAsync()
        continue
    }
    Start-Sleep -Milliseconds 15
}
$p.WaitForExit()
$form.Dispose()
# The player removes its control files (next to the args file) when the
# warm-up ends. A player that was killed or crashed meanwhile cannot: its
# warm-up still finishes and writes the stamp, but the lock would make the
# next player's "Rebuild shaders" wait ~5 min for "the other mpv".
if ($Owner -ne 0 -and -not [ShaderCache.Native]::IsWindow([IntPtr]$Owner)) {
    $dir = Split-Path -Parent $ArgsFile
    foreach ($name in 'shader-warmup.lock', 'shader-warmup.progress', (Split-Path -Leaf $ArgsFile)) {
        Remove-Item -LiteralPath (Join-Path $dir $name) -ErrorAction SilentlyContinue
    }
}
exit $p.ExitCode
