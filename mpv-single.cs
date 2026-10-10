// Single-instance launcher for mpv on Windows.
//
// Registered as an alternate "Open with" handler (see mpv-single-register.ps1).
// Normal open: reuses one mpv window, swaps its playlist via JSON IPC
// (loadfile ... replace) and raises it. Ctrl held at launch: always starts a
// fresh, untracked mpv window instead.
//
// Several files opened at once: Explorer starts one launcher per selected
// file, all within a few milliseconds. Each found no pipe yet and started its
// own mpv - three files, three windows (measured 2026-10-10), and had the race
// been won, each "replace" would have left only the last file. The launchers
// now take turns through a named mutex; the one that starts mpv keeps it until
// mpv's pipe answers, and every launcher keeps it HoldMs after its file went
// out. A launcher started within TogetherMs of the one before it (each notes
// its start time in a small shared memory block) was opened together with it
// and appends its file to the playlist; one opened later replaces what plays,
// as before - also while an mpv is still starting.
//
// Rebuild after editing:
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /out:mpv-single.exe mpv-single.cs
using System;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

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
    // per Windows session, like the pipe's users
    const string GateName = "Local\\mpv-single-launch";
    // the start time of the launcher before this one; it exists while a
    // launcher runs, and HoldMs keeps one running through a burst
    const string LastStartName = "Local\\mpv-single-last-start";
    // launchers started this close together were opened together (Explorer
    // starts one per selected file within milliseconds)
    const int TogetherMs = 1000;
    // how long a launcher keeps the gate (and the start time) after its file
    // went out, so the rest of a burst still finds them
    const int HoldMs = 700;
    // how long the launcher that started mpv waits for mpv's pipe
    const int PipeWaitMs = 8000;

    [STAThread]
    static void Main(string[] args)
    {
        if (args.Length == 0)
            return;

        string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
        string mpvCom = Path.Combine(exeDir, "mpv.com");

        bool ctrlHeld = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0;
        if (ctrlHeld)
        {
            LaunchNewInstance(mpvCom, args, addIpcServer: false);
            return;
        }

        using (var gate = new Mutex(false, GateName))
        using (var lastStart = MemoryMappedFile.CreateOrOpen(LastStartName, 8))
        using (var last = lastStart.CreateViewAccessor(0, 8))
        {
            bool owned;
            try
            {
                owned = gate.WaitOne(PipeWaitMs + HoldMs + 2000);
            }
            catch (AbandonedMutexException)
            {
                // a launcher that held it died: the gate is ours now
                owned = true;
            }
            try
            {
                long started = Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks;
                long before = last.ReadInt64(0);
                last.Write(0, started);
                bool together = before != 0 && Math.Abs(started - before) <= TimeSpan.FromMilliseconds(TogetherMs).Ticks;
                if (TrySendToRunningInstance(args, append: together))
                {
                    // Handing the playlist to the running mpv is only half the job.
                    // Without this the file starts playing behind whatever window the
                    // user was looking at, which reads as "nothing happened". mpv's
                    // IPC has no raise command, so do it from here: this process was
                    // just started by the user's own click, so it still holds the
                    // foreground rights Windows would deny mpv itself.
                    RaiseRunningInstance();
                }
                else
                {
                    WaitForPipe(LaunchNewInstance(mpvCom, args, addIpcServer: true));
                }
                Thread.Sleep(HoldMs);
            }
            finally
            {
                if (owned)
                    gate.ReleaseMutex();
            }
        }
    }

    // Until the mpv just started answers on its pipe (or exits): the next
    // launcher of a burst must find it, not start another one.
    static void WaitForPipe(Process mpv)
    {
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < PipeWaitMs)
        {
            if (mpv == null || mpv.HasExited)
                return;
            try
            {
                using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
                {
                    pipe.Connect(100);
                    return;
                }
            }
            catch
            {
                Thread.Sleep(50);
            }
        }
    }

    // append: the file joins the playlist (the rest of a burst) instead of
    // replacing what plays
    static bool TrySendToRunningInstance(string[] files, bool append)
    {
        try
        {
            using (var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out))
            {
                pipe.Connect(250);
                var sb = new StringBuilder();
                for (int i = 0; i < files.Length; i++)
                {
                    string flag = i == 0 && !append ? "replace" : "append";
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

    static Process LaunchNewInstance(string mpvCom, string[] files, bool addIpcServer)
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
        return Process.Start(psi);
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
