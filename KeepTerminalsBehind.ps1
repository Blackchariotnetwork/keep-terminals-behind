<#
.SYNOPSIS
  Keeps cmd / PowerShell / Windows Terminal windows from interrupting you.

.DESCRIPTION
  v9 - EVENT-DRIVEN; suppression = hide + move off-screen, ALWAYS. Background
  console spawns are never visible, even when they appear under the cursor.

  Registers Windows event hooks (SetWinEventHook) for focus changes and
  window-show events, plus a fast 100ms sweep as a backstop for windows
  that get raised without taking focus.

  Suppression ladder for a popup console window:
    1st offense: minimized (still findable in the taskbar)
    2nd offense: hidden completely (no screen, no taskbar entry)

  Safety rules:
    - If the MOUSE CURSOR is over a console window when it takes focus,
      YOU put it there -> it is marked user-owned and never suppressed.
    - Minimized/hidden windows are left alone.
    - Regular windows (browsers, editors, etc.) are never touched.

  Diagnostics: logged to %TEMP%\KeepTerminalsBehind.log (-DisableLog to stop).

  To stop it:
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -match 'KeepTerminalsBehind' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId }

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\KeepTerminalsBehind.ps1
#>

param(
    [string[]]$ProcessNames = @('cmd', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost', 'mintty', 'wt', 'OpenConsole', 'node'),
    [string]$LogPath = "$env:TEMP\KeepTerminalsBehind.log",
    [switch]$DisableLog
)

if ($DisableLog) { $LogPath = '' }
$script:ProcNames = $ProcessNames
$script:LogPath = $LogPath

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

namespace KTB
{
    public static class Hook
    {
        // ---------- Win32 ----------
        public delegate void WinEventDelegate(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate pfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG lpMsg);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG lpMsg);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

        public struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }
        public struct POINT { public int X; public int Y; }
        public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

        // ---------- constants ----------
        const uint EVENT_SYSTEM_FOREGROUND = 0x0002;
        const uint EVENT_OBJECT_SHOW       = 0x8002;
        const uint WINEVENT_OUTOFCONTEXT   = 0;
        static readonly IntPtr HWND_BOTTOM = new IntPtr(6);
        const uint SWP_FLAGS = 0x0001 | 0x0002 | 0x0010 | 0x0200; // NOSIZE|NOMOVE|NOACTIVATE|NOOWNERZORDER
        const uint GW_HWNDLAST = 1;
        const byte VK_MENU = 0x12;
        const uint KEYEVENTF_KEYUP = 2;
        const int SW_MINIMIZE = 6;
        const int SW_HIDE = 0;

        static readonly string[] ConsoleClasses = new string[] { "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PseudoConsoleWindow", "mintty" };
        const string DragBarClass = "DRAG_BAR_WINDOW_CLASS"; // WT-internal child window - never touch
        static HashSet<string> procNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ---------- state ----------
        static readonly object gate = new object();
        static IntPtr lastGood = IntPtr.Zero;
        static readonly Dictionary<string, DateTime> foreignLog = new Dictionary<string, DateTime>();
        static readonly Dictionary<IntPtr, int> violations = new Dictionary<IntPtr, int>();
        static readonly HashSet<IntPtr> seenWindows = new HashSet<IntPtr>();   // windows observed at show-time
        static string logPath = "";
        static WinEventDelegate fgHandler;
        static WinEventDelegate showHandler;

        static void Log(string fmt, params object[] args)
        {
            if (logPath == "") return;
            try
            {
                lock (gate)
                {
                    var line = DateTime.Now.ToString("HH:mm:ss.fff") + "  " + string.Format(fmt, args);
                    var fi = new FileInfo(logPath);
                    if (fi.Exists && fi.Length > 1048576) File.WriteAllText(logPath, line + Environment.NewLine);
                    else File.AppendAllText(logPath, line + Environment.NewLine);
                }
            }
            catch { }
        }

        static string Describe(IntPtr hwnd)
        {
            var sb = new System.Text.StringBuilder(256);
            GetClassName(hwnd, sb, 256);
            string cls = sb.ToString();
            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            string proc = "?";
            try { proc = Process.GetProcessById((int)pid).ProcessName; } catch { }
            return cls + "/" + proc + "/pid" + pid;
        }

        static bool IsConsoleWindow(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            var sb = new System.Text.StringBuilder(256);
            GetClassName(hwnd, sb, 256);
            string cls = sb.ToString();
            if (cls == DragBarClass) return false;   // WT-internal child, never manage
            foreach (string c in ConsoleClasses) if (cls == c) return true;

            uint pid;
            GetWindowThreadProcessId(hwnd, out pid);
            if (pid == 0) return false;
            try
            {
                string name = Process.GetProcessById((int)pid).ProcessName;
                return procNames.Contains(name);
            }
            catch { return false; }
        }

        static bool IsAtBottom(IntPtr hwnd)
        {
            IntPtr last = GetWindow(hwnd, GW_HWNDLAST);
            return last == IntPtr.Zero || last == hwnd;
        }

        // Suppression ladder: minimize once, then hide on repeat offenses
        static void Suppress(IntPtr hwnd, string reason)
        {
            int count;
            lock (gate)
            {
                if (!violations.TryGetValue(hwnd, out count)) count = 0;
                violations[hwnd] = count + 1;
                count = count + 1;
            }

            // Hide immediately AND move far off-screen. Some hosts (newer
            // Windows Terminal) can ignore or re-show a hidden window, so the
            // off-screen move guarantees it can never paint over your work
            // even if a hide or show event is missed.
            ShowWindowAsync(hwnd, SW_HIDE);
            SetWindowPos(hwnd, IntPtr.Zero, -32000, -32000, 0, 0, 0x0001 | 0x0004 | 0x0010 | 0x0200); // NOSIZE|NOZORDER|NOACTIVATE|NOOWNERZORDER
            Log("SUPPRESSED ({0}) strike {1} -> HIDDEN {2}", reason, count, Describe(hwnd));
        }

        static void RestoreFocus(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
            keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            SetForegroundWindow(hwnd);
        }

        static bool CursorInside(IntPtr hwnd)
        {
            POINT p; RECT r;
            GetCursorPos(out p);
            GetWindowRect(hwnd, out r);
            return p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom;
        }

        // Diagnostics: rate-limited log of NON-console windows taking the
        // foreground, so anything we do NOT manage shows up in the log.
        static void LogForeign(IntPtr hwnd)
        {
            if (logPath == "") return;
            try
            {
                var sb = new System.Text.StringBuilder(256);
                GetClassName(hwnd, sb, 256);
                string cls = sb.ToString();
                if (cls == "WorkerW" || cls == "Progman" || cls == "Shell_TrayWnd") return;
                uint pid; GetWindowThreadProcessId(hwnd, out pid);
                string proc = "?";
                try { proc = Process.GetProcessById((int)pid).ProcessName; } catch { }
                string key = cls + "/" + proc;
                DateTime last;
                lock (gate)
                {
                    if (foreignLog.TryGetValue(key, out last) && (DateTime.Now - last).TotalSeconds < 10) return;
                    foreignLog[key] = DateTime.Now;
                }
                Log("FG -> other {0} (not managed)", key);
            }
            catch { }
        }

        // EVENT_OBJECT_SHOW: a window just became visible
        static void ShowHandler(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (idObject != 0) return;
            if (!IsConsoleWindow(hwnd)) return;
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            lock (gate) { seenWindows.Add(hwnd); }   // observed alive at show-time

            IntPtr fg = GetForegroundWindow();
            if (fg == hwnd) HandleForeground(hwnd);
            else
            {
                // Fresh spawn: hide it no matter what, even if it appeared
                // under the cursor. Background spawns must never be visible.
                Suppress(hwnd, "show");
            }
        }

        // EVENT_SYSTEM_FOREGROUND: the foreground window changed
        static void FgHandler(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (idObject != 0 || idChild != 0) return;
            HandleForeground(hwnd);
        }

        static void HandleForeground(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;

            if (!IsConsoleWindow(hwnd))
            {
                lock (gate) { lastGood = hwnd; }
                LogForeign(hwnd);
                return;
            }

            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            if (CursorInside(hwnd))
            {
                bool seen;
                lock (gate) { seen = seenWindows.Contains(hwnd); }
                if (!seen)
                {
                    // Became foreground with the cursor over it but was never
                    // observed as a shown window first: a self-activating
                    // spawn. Hide it and hand focus back.
                    Suppress(hwnd, "fg-spawn");
                    RestoreFocus(lastGood);
                    return;
                }
                Log("FG -> console {0} CURSOR INSIDE - user-owned, protected", Describe(hwnd));
                return;
            }

            if (hwnd == lastGood) return;

            Log("FG -> console {0} POPUP (cursor elsewhere)", Describe(hwnd));
            Suppress(hwnd, "fg");
            RestoreFocus(lastGood);
        }

        // Fast backstop: catches windows raised WITHOUT taking focus,
        // which is exactly what keeps flashing in front of the browser.
        static void Backstop(object state)
        {
            try
            {
                IntPtr fg = GetForegroundWindow();

                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    if (IsWindowVisible(h) && !IsIconic(h) && IsConsoleWindow(h))
                    {
                        if (h == fg || CursorInside(h)) return true;
                        if (IsAtBottom(h)) return true;
                        Suppress(h, "sweep");
                    }
                    return true;
                }, IntPtr.Zero);

                if (fg != IntPtr.Zero && !IsConsoleWindow(fg))
                {
                    lock (gate) { lastGood = fg; }
                }

                // prune dead handles
                lock (gate)
                {
                    if (violations.Count > 50)
                    {
                        var deadV = new List<IntPtr>();
                        foreach (var kv in violations) if (!IsWindow(kv.Key)) deadV.Add(kv.Key);
                        foreach (var h in deadV) violations.Remove(h);
                        var deadS = new List<IntPtr>();
                        foreach (var h in seenWindows) if (!IsWindow(h)) deadS.Add(h);
                        foreach (var h in deadS) seenWindows.Remove(h);
                    }
                }
            }
            catch { }
        }

        public static void Run(string[] names, string logFile)
        {
            foreach (string n in names) procNames.Add(n);
            logPath = logFile == null ? "" : logFile;
            Log("===== KeepTerminalsBehind v9 started =====");

            fgHandler = new WinEventDelegate(FgHandler);
            showHandler = new WinEventDelegate(ShowHandler);

            IntPtr h1 = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, fgHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            IntPtr h2 = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, showHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            Log("hooks: fg=0x{0} show=0x{1}", h1.ToString("X"), h2.ToString("X"));
            if (h1 == IntPtr.Zero && h2 == IntPtr.Zero) Log("WARNING: no hooks registered!");

            var backstop = new System.Threading.Timer(Backstop, null, 100, 100);

            MSG msg;
            while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }
    }
}
"@

Write-Host "KeepTerminalsBehind v9 (hide + off-screen, no visible spawns) is running." -ForegroundColor Cyan
if ($script:LogPath) { Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray }

[KTB.Hook]::Run($script:ProcNames, $script:LogPath)
