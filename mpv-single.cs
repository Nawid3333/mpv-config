// Single-instance launcher for mpv on Windows.
//
// Registered as an alternate "Open with" handler (see mpv-single-register.ps1).
// Normal open: reuses one mpv window, swaps its playlist via JSON IPC
// (loadfile ... replace) and raises it. Ctrl held at launch: always starts a
// fresh, untracked mpv window instead.
//
// Rebuild after editing:
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:mpv-single.exe mpv-single.cs
using System;
using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

static class MpvSingle
{
    [DllImport("user32.dll")]
    static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    static extern bool IsIconic(IntPtr hWnd);

    const int VK_CONTROL = 0x11;
    const int SW_RESTORE = 9;
    const string PipeName = "mpv-single";

    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length == 0)
            return;

        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string mpvCom = Path.Combine(exeDir, "mpv.com");

        bool ctrlHeld = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;

        if (!ctrlHeld && TrySendToRunningInstance(args))
        {
            // Handing the playlist to the running mpv is only half the job.
            // Without this the file starts playing behind whatever window the
            // user was looking at, which reads as "nothing happened". mpv's
            // IPC has no raise command, so do it from here: this process was
            // just started by the user's own click, so it still holds the
            // foreground rights Windows would deny mpv itself.
            RaiseRunningInstance();
            return;
        }

        LaunchNewInstance(mpvCom, args, addIpcServer: !ctrlHeld);
    }

    static bool TrySendToRunningInstance(string[] files)
    {
        try
        {
            using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
            {
                pipe.Connect(250);
                var sb = new StringBuilder();
                for (int i = 0; i < files.Length; i++)
                {
                    string flag = i == 0 ? "replace" : "append";
                    sb.Append("{\"command\":[\"loadfile\",\"")
                      .Append(JsonEscape(files[i]))
                      .Append("\",\"")
                      .Append(flag)
                      .Append("\"]}\n");
                }
                byte[] bytes = new UTF8Encoding(false).GetBytes(sb.ToString());
                pipe.Write(bytes, 0, bytes.Length);
                pipe.Flush();
                pipe.WaitForPipeDrain();
                return true;
            }
        }
        catch
        {
            return false;
        }
    }

    static void RaiseRunningInstance()
    {
        try
        {
            foreach (var p in Process.GetProcessesByName("mpv"))
            {
                IntPtr h = p.MainWindowHandle;
                if (h == IntPtr.Zero)
                    continue;
                if (IsIconic(h))
                    ShowWindow(h, SW_RESTORE);
                SetForegroundWindow(h);
                return;
            }
        }
        catch
        {
            // Best effort only. The file is already loading either way, so a
            // failure here must never become a visible error.
        }
    }

    static void LaunchNewInstance(string mpvCom, string[] files, bool addIpcServer)
    {
        var sb = new StringBuilder();
        if (addIpcServer)
            sb.Append("--input-ipc-server=\\\\.\\pipe\\").Append(PipeName).Append(' ');
        foreach (var f in files)
            sb.Append(QuoteArg(f)).Append(' ');

        var psi = new ProcessStartInfo
        {
            FileName = mpvCom,
            Arguments = sb.ToString().Trim(),
            UseShellExecute = false,
            // mpv.com is a console binary and this launcher is a winexe, so
            // without this Windows allocates a fresh console for every single
            // launch - a black box flashing up on each opened file.
            CreateNoWindow = true,
        };
        Process.Start(psi);
    }

    // Quote one argument the way CommandLineToArgvW (and therefore mpv) parses
    // it back. The naive version - wrap in quotes, escape any embedded quote -
    // breaks on a path ending in a backslash, which Explorer hands out for
    // directories: "C:\Videos\" escapes its own closing quote and swallows the
    // rest of the command line. Backslashes are only special immediately
    // before a quote, where each one has to be doubled.
    static string QuoteArg(string s)
    {
        var sb = new StringBuilder("\"");
        int backslashes = 0;
        foreach (char c in s)
        {
            if (c == '\\')
            {
                backslashes++;
                continue;
            }
            if (c == '"')
                sb.Append('\\', backslashes * 2 + 1).Append('"');
            else
                sb.Append('\\', backslashes).Append(c);
            backslashes = 0;
        }
        // Trailing run: doubled so it stays literal instead of escaping the
        // closing quote appended right after it.
        sb.Append('\\', backslashes * 2).Append('"');
        return sb.ToString();
    }

    static string JsonEscape(string s)
    {
        return s.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
