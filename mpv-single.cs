// Single-instance launcher for mpv on Windows.
//
// mpv-single-register.ps1 makes it the command of mpv's own file types, so a
// file opened from Explorer comes here instead of starting another mpv.
//
// Where a file goes: local files share a window, streams keep their own. Every
// mpv this launcher starts has its own pipe (mpv-single-<id>); a file goes to
// the front-most of them - the window used last - that plays a local file or
// nothing. A window playing a stream (any URL: HLS, YouTube, ...) is never
// taken over, and FastStream's mpv has no such pipe at all. No such window: a
// new mpv. Ctrl held at launch, or --new-window: always a new mpv.
//
// The hand-off goes to the mpv's single-instance.lua (script-message-to
// single_instance open ...), which replaces what plays and offers, in a corner
// banner, to put it back and play the new file in a new window - it starts
// this launcher with --new-window [--start=<seconds>] for that. An mpv without
// the script (an older config, a test) gets plain loadfile commands.
//
// Several files opened at once: Explorer starts one launcher per selected
// file, all within a few milliseconds. Each found no pipe yet and started its
// own mpv - three files, three windows - and had the race been won, each
// "replace" would have left only the last file. The launchers take turns
// through a named mutex; the one that starts mpv keeps it until mpv's pipe
// answers, and every launcher keeps it HoldMs after its file went out. A
// launcher started within TogetherMs of the one before it (each notes its
// start time and the pipe it used in a small shared memory block) was opened
// together with it and appends its file to that pipe's playlist; one opened
// later picks its window anew and replaces what plays - also while an mpv is
// still starting.
//
// The window raised after a hand-off is the one of the mpv behind the pipe
// (GetNamedPipeServerProcessId), not the first process named mpv with a window,
// which with a second mpv open (FastStream's, a Ctrl one) could bring that one
// forward while the file played in the other.
//
// For the tests: MPV_SINGLE_RAISE_LOG names a file the launcher writes the
// process id it would raise into, raising nothing; MPV_SINGLE_PIPE_PREFIX
// gives their mpv players pipes of their own, which the launcher of a file
// opened from Explorer meanwhile never sees (nor they the owner's mpv);
// MPV_SINGLE_CTRL=1 stands for Ctrl held (no key press can be sent).
//
// Rebuild after editing, and commit both (the exe carries this file as a resource, and the
// static tier checks it is this very text):
//   C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /target:winexe /resource:mpv-single.cs /out:mpv-single.exe mpv-single.cs
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.IO.Pipes;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

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

    [DllImport("dwmapi.dll")]
    static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out int value, int size);

    const int DWMWA_CLOAKED = 14;

    [DllImport("user32.dll")]
    static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);

    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetNamedPipeServerProcessId(SafePipeHandle pipe, out uint serverProcessId);

    // WIN32_FIND_DATA. Its times are FILETIMEs, two 32-bit halves each: as
    // longs they would be 8-byte aligned, and the padding shifts the name.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct FindData
    {
        public uint Attributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME Created, Accessed, Written;
        public uint SizeHigh, SizeLow, Reserved0, Reserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)]
        public string ShortName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr FindFirstFile(string pattern, out FindData data);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern bool FindNextFile(IntPtr find, out FindData data);

    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr find);

    const int VK_CONTROL = 0x11;
    const int SW_RESTORE = 9;
    // every mpv this launcher starts listens on PipePrefix-<id>; a plain
    // PipePrefix is the one pipe of an mpv an older launcher started
    static readonly string PipePrefix = Environment.GetEnvironmentVariable("MPV_SINGLE_PIPE_PREFIX") ?? "mpv-single";
    // the Lua script that takes the hand-off (single-instance.lua)
    const string ScriptName = "single_instance";
    // per Windows session, like the pipes' users
    const string GateName = "Local\\mpv-single-launch";
    // the burst: [0,8) the start time of the launcher before this one, [8,10)
    // the length of the pipe name it used, then the name in UTF-16, then 1 if
    // it was opened with Ctrl held. It exists while a launcher runs, and HoldMs
    // keeps one running through a burst.
    const string BurstName = "Local\\mpv-single-burst";
    const int BurstNameChars = 64;
    const int BurstCtrlAt = 10 + 2 * BurstNameChars;
    // A burst of 15 files (Explorer's most) takes its last launcher about 11 s
    // to get the gate; one that waits longer than this gives its file its own
    // mpv rather than race the others for the playlist.
    const int GateWaitMs = 60000;
    // launchers started this close together were opened together (Explorer
    // starts one per selected file within milliseconds)
    const int TogetherMs = 1000;
    // how long a launcher keeps the gate (and the burst) after its file went
    // out, so the rest of a burst still finds them
    const int HoldMs = 700;
    // how long the launcher that started mpv waits for mpv's pipe
    const int PipeWaitMs = 8000;
    // how long an mpv may take to answer a request on its pipe; one that does
    // not answer is busy or hung, and gets no file
    const int ReplyMs = 1500;

    static int requestId;

    [STAThread]
    static void Main(string[] argv)
    {
        bool newWindow = false;
        string start = null;
        int first = 0;
        for (; first < argv.Length; first++)
        {
            string a = argv[first];
            if (a == "--")
            {
                first++;
                break;
            }
            if (a == "--new-window")
                newWindow = true;
            else if (a.StartsWith("--start=", StringComparison.Ordinal) && Regex.IsMatch(a.Substring(8), @"^\d+(\.\d+)?$"))
                start = a.Substring(8);
            else
                break;
        }
        var files = new string[argv.Length - first];
        Array.Copy(argv, first, files, 0, files.Length);
        if (files.Length == 0)
            return;

        string launcher = Assembly.GetExecutingAssembly().Location;
        string mpvCom = Path.Combine(Path.GetDirectoryName(launcher), "mpv.com");

        // The banner's way out (single-instance.lua): its own mpv at once, never
        // part of a burst - a click on the banner within TogetherMs of the open
        // would otherwise send the file back into the window it is leaving.
        if (newWindow)
        {
            string pipe = NewPipeName();
            Process mpv = LaunchNewInstance(mpvCom, files, start, pipe);
            WaitForPipe(mpv, pipe);
            RaiseWhenShown(pipe);
            return;
        }

        bool ctrlHeld = (GetAsyncKeyState(VK_CONTROL) & 0x8000) != 0 ||
            Environment.GetEnvironmentVariable("MPV_SINGLE_CTRL") == "1";
        using (var gate = new Mutex(false, GateName))
        using (var burstMap = MemoryMappedFile.CreateOrOpen(BurstName, BurstCtrlAt + 1))
        using (var burst = burstMap.CreateViewAccessor())
        {
            try
            {
                if (!gate.WaitOne(GateWaitMs))
                {
                    // the launchers before it still hold the gate: neither the burst
                    // nor a running mpv's playlist is this one's to touch
                    LaunchNewInstance(mpvCom, files, null, NewPipeName());
                    return;
                }
            }
            catch (AbandonedMutexException)
            {
                // a launcher that held it died: the gate is ours now
            }
            try
            {
                long started = Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks;
                long before = burst.ReadInt64(0);
                string burstPipe = ReadBurstPipe(burst);
                bool burstCtrl = burst.ReadByte(BurstCtrlAt) != 0;
                burst.Write(0, started);
                // A Ctrl file joins only a burst opened with Ctrl (its new window), a
                // plain file only a plain one: a file Ctrl-opened right after another
                // was opened gets a new window, not the other's playlist.
                bool together = before != 0 && burstPipe != null && burstCtrl == ctrlHeld &&
                    Math.Abs(started - before) <= TimeSpan.FromMilliseconds(TogetherMs).Ticks;

                int server = 0;
                string target = null;
                if (together && HandOff(burstPipe, files, "append", launcher, out server))
                    target = burstPipe;
                // Ctrl: a new window for this file (the rest of its burst joins it above)
                if (target == null && !ctrlHeld)
                {
                    string found = FindTarget();
                    if (found != null && HandOff(found, files, "replace", launcher, out server))
                        target = found;
                }
                if (target != null)
                {
                    WriteBurstPipe(burst, target, ctrlHeld);
                    // Handing the playlist to the running mpv is only half the job.
                    // Without this the file starts playing behind whatever window the
                    // user was looking at, which reads as "nothing happened". mpv's
                    // IPC has no raise command, so do it from here: this process was
                    // just started by the user's own click, so it still holds the
                    // foreground rights Windows would deny mpv itself.
                    RaiseRunningInstance(server);
                }
                else
                {
                    string pipe = NewPipeName();
                    WriteBurstPipe(burst, pipe, ctrlHeld);
                    WaitForPipe(LaunchNewInstance(mpvCom, files, null, pipe), pipe);
                }
                Thread.Sleep(HoldMs);
            }
            finally
            {
                gate.ReleaseMutex();
            }
        }
    }

    static string NewPipeName()
    {
        return PipePrefix + "-" + Guid.NewGuid().ToString("N").Substring(0, 12);
    }

    static string ReadBurstPipe(MemoryMappedViewAccessor burst)
    {
        int n = burst.ReadUInt16(8);
        if (n == 0 || n > BurstNameChars)
            return null;
        var name = new char[n];
        burst.ReadArray(10, name, 0, n);
        return new string(name);
    }

    static void WriteBurstPipe(MemoryMappedViewAccessor burst, string pipe, bool ctrl)
    {
        burst.Write(8, (ushort)pipe.Length);
        burst.WriteArray(10, pipe.ToCharArray(), 0, pipe.Length);
        burst.Write(BurstCtrlAt, (byte)(ctrl ? 1 : 0));
    }

    // The pipes of the mpv players this launcher started (\\.\pipe\ lists them
    // like files).
    static List<string> ListPipes()
    {
        var pipes = new List<string>();
        FindData data;
        IntPtr find = FindFirstFile(@"\\.\pipe\*", out data);
        if (find == new IntPtr(-1))
            return pipes;
        try
        {
            do
            {
                string n = data.Name;
                if (n == PipePrefix || n.StartsWith(PipePrefix + "-", StringComparison.Ordinal))
                    pipes.Add(n);
            } while (FindNextFile(find, out data));
        }
        finally
        {
            FindClose(find);
        }
        return pipes;
    }

    // The pipe of the window to play a local file in: the front-most mpv window
    // (the one used last) that plays a local file or nothing, and is not minimized -
    // a minimized window keeps its place in the z-order, but it was put away; null
    // for none. Only when every one is minimized does the front-most of them get it
    // (RaiseRunningInstance restores it), and one on another virtual desktop only
    // when no window is on this one.
    static string FindTarget()
    {
        var local = new Dictionary<uint, string>();
        string windowless = null;
        foreach (string pipe in ListPipes())
        {
            uint pid;
            string path;
            if (!Probe(pipe, out pid, out path) || IsStream(path))
                continue;
            local[pid] = pipe;
            if (windowless == null)
                windowless = pipe;
        }
        if (local.Count == 0)
            return null;
        string front = null;
        string minimized = null;
        string elsewhere = null;
        // EnumWindows walks the top-level windows front to back
        EnumWindows((h, _) =>
        {
            uint pid;
            string pipe;
            int cloaked;
            if (!IsWindowVisible(h))
                return true;
            GetWindowThreadProcessId(h, out pid);
            if (!local.TryGetValue(pid, out pipe))
                return true;
            // "visible" also on another virtual desktop, where Windows cloaks it: a file
            // sent there plays where nobody sees it
            if (DwmGetWindowAttribute(h, DWMWA_CLOAKED, out cloaked, 4) == 0 && cloaked != 0)
            {
                if (elsewhere == null)
                    elsewhere = pipe;
                return true;
            }
            if (!IsIconic(h))
            {
                front = pipe;
                return false;
            }
            if (minimized == null)
                minimized = pipe;
            return true;
        }, IntPtr.Zero);
        // none shows a window (an mpv starting, a null video output): any of them
        return front ?? minimized ?? elsewhere ?? windowless;
    }

    // A URL is a stream (HLS, YouTube, av://, ...); a path, file:// or nothing
    // (idle) is local.
    static bool IsStream(string path)
    {
        return path != null && Regex.IsMatch(path, @"^[A-Za-z][A-Za-z0-9+.\-]*://") &&
            !path.StartsWith("file://", StringComparison.OrdinalIgnoreCase);
    }

    // What the mpv behind a pipe plays (null: nothing) and its process id;
    // false when it does not answer.
    static bool Probe(string pipeName, out uint pid, out string path)
    {
        pid = 0;
        path = null;
        try
        {
            using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                pipe.Connect(250);
                if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out pid))
                    pid = 0;
                string reply = Request(pipe, "[\"get_property\",\"path\"]");
                if (reply == null)
                    return false;
                // no file: "error":"property unavailable" and no data
                path = JsonString(reply, "data");
                return true;
            }
        }
        catch
        {
            return false;
        }
    }

    // Sends one command (a JSON array) and returns mpv's reply line to it, or
    // null when none came within ReplyMs. mpv also writes its events to every
    // client; they carry no request_id of ours.
    static string Request(NamedPipeClientStream pipe, string command)
    {
        int id = ++requestId + 100;
        byte[] bytes = new UTF8Encoding(false).GetBytes("{\"command\":" + command + ",\"request_id\":" + id + "}\n");
        pipe.Write(bytes, 0, bytes.Length);
        pipe.Flush();
        var reader = new StreamReader(pipe, new UTF8Encoding(false));
        var mine = new Regex("\"request_id\"\\s*:\\s*" + id + "\\b");
        var clock = Stopwatch.StartNew();
        while (true)
        {
            int left = ReplyMs - (int)clock.ElapsedMilliseconds;
            if (left <= 0)
                return null;
            var line = reader.ReadLineAsync();
            if (!line.Wait(left) || line.Result == null)
                return null;
            if (mine.IsMatch(line.Result))
                return line.Result;
        }
    }

    // The string value of a top-level field of mpv's JSON reply; null when the
    // field is missing or not a string.
    static string JsonString(string json, string field)
    {
        var m = Regex.Match(json, "\"" + field + "\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");
        if (!m.Success)
            return null;
        return Regex.Replace(m.Groups[1].Value, @"\\(u[0-9a-fA-F]{4}|.)", e =>
        {
            string s = e.Groups[1].Value;
            switch (s[0])
            {
                case 'u': return ((char)Convert.ToInt32(s.Substring(1), 16)).ToString();
                case 'n': return "\n";
                case 'r': return "\r";
                case 't': return "\t";
                case 'b': return "\b";
                case 'f': return "\f";
                default: return s;
            }
        });
    }

    // Until the mpv just started answers on its pipe (or exits): the next
    // launcher of a burst must find it, not start another one.
    static void WaitForPipe(Process mpv, string pipeName)
    {
        var clock = Stopwatch.StartNew();
        while (clock.ElapsedMilliseconds < PipeWaitMs)
        {
            if (mpv == null || mpv.HasExited)
                return;
            try
            {
                using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
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

    // mode: "replace" what plays, or "append" (the rest of a burst); server: the
    // id of the mpv process behind the pipe, 0 when Windows does not say
    static bool HandOff(string pipeName, string[] files, string mode, string launcher, out int server)
    {
        server = 0;
        try
        {
            using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous))
            {
                pipe.Connect(250);
                uint id;
                if (GetNamedPipeServerProcessId(pipe.SafePipeHandle, out id))
                    server = (int)id;
                var cmd = new StringBuilder("[\"script-message-to\",\"" + ScriptName + "\",\"open\",\"")
                    .Append(mode).Append("\",\"").Append(JsonEscape(launcher)).Append('"');
                foreach (string f in files)
                    cmd.Append(",\"").Append(JsonEscape(f)).Append('"');
                cmd.Append(']');
                string reply = Request(pipe, cmd.ToString());
                // No answer in time: mpv is busy and runs the message when it
                // gets to it - sending loadfile as well would play the file twice.
                if (reply == null || reply.Contains("\"error\":\"success\""))
                    return true;
                // no such script (an older config): mpv's own commands
                var sb = new StringBuilder();
                for (int i = 0; i < files.Length; i++)
                {
                    string flag = i == 0 && mode == "replace" ? "replace" : "append";
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

    // server: the mpv that got the file; 0 (Windows did not say which) falls
    // back to the first mpv with a window
    static void RaiseRunningInstance(int server)
    {
        try
        {
            string log = Environment.GetEnvironmentVariable("MPV_SINGLE_RAISE_LOG");
            if (!string.IsNullOrEmpty(log))
            {
                File.WriteAllText(log, server.ToString());
                return;
            }
            Process[] candidates = server > 0
                ? new[] { Process.GetProcessById(server) }
                : Process.GetProcessesByName("mpv");
            foreach (var p in candidates)
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

    // A new window opened from another mpv's banner: mpv.com hands the start to
    // mpv.exe, which may not take the foreground itself; this launcher, started
    // by the mpv just clicked, may give it.
    static void RaiseWhenShown(string pipeName)
    {
        int server = 0;
        try
        {
            using (var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.Out))
            {
                pipe.Connect(250);
                uint id;
                if (GetNamedPipeServerProcessId(pipe.SafePipeHandle, out id))
                    server = (int)id;
            }
            var clock = Stopwatch.StartNew();
            while (server > 0 && clock.ElapsedMilliseconds < 5000 &&
                Process.GetProcessById(server).MainWindowHandle == IntPtr.Zero)
                Thread.Sleep(100);
        }
        catch
        {
            return;
        }
        if (server > 0)
            RaiseRunningInstance(server);
    }

    // start: the first file's start position in seconds (a file that already
    // played a while in the window it leaves), as a per-file option so the
    // files handed to this mpv later start at their beginning
    static Process LaunchNewInstance(string mpvCom, string[] files, string start, string pipeName)
    {
        // mpv.exe started from Explorer runs as a GUI program (pseudo-gui: a
        // window at once, also for a song without a picture); through mpv.com's
        // console it would not, so it is asked for.
        var sb = new StringBuilder("--player-operation-mode=pseudo-gui --input-ipc-server=\\\\.\\pipe\\").Append(pipeName).Append(' ');
        for (int i = 0; i < files.Length; i++)
        {
            if (i == 0 && start != null)
                sb.Append("--{ --start=").Append(start).Append(' ').Append(QuoteArg(files[i])).Append(" --} ");
            else
                sb.Append(QuoteArg(files[i])).Append(' ');
        }

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
        var sb = new StringBuilder();
        foreach (char c in s)
        {
            if (c == '\\' || c == '"')
                sb.Append('\\').Append(c);
            else if (c < 0x20)
                sb.Append("\\u").Append(((int)c).ToString("x4"));
            else
                sb.Append(c);
        }
        return sb.ToString();
    }
}
