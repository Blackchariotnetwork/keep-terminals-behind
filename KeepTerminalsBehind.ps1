<#
.SYNOPSIS
  Keeps cmd / PowerShell / Windows Terminal windows from interrupting you.

.DESCRIPTION
  v6 - EVENT-DRIVEN with fast sweep + two-strike suppression.

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
    [string[]]$ProcessNames = @('cmd', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost'),
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

        static readonly string[] ConsoleClasses = new string[] { "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS", "PseudoConsoleWindow" };
        const string DragBarClass = "DRAG_BAR_WINDOW_CLASS"; // WT-internal child window - never touch
        static HashSet<string> procNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ---------- state ----------
        static readonly object gate = new object();
        static IntPtr lastGood = IntPtr.Zero;
        static readonly HashSet<IntPtr> userOwned = new HashSet<IntPtr>();     // consoles the user clicked into
        static readonly Dictionary<IntPtr, int> violations = new Dictionary<IntPtr, int>();
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

            if (count >= 2)
            {
                ShowWindowAsync(hwnd, SW_HIDE);
                Log("SUPPRESSED ({0}) strike {1} -> HIDDEN {2}", reason, count, Describe(hwnd));
            }
            else
            {
                ShowWindowAsync(hwnd, SW_MINIMIZE);
                Log("SUPPRESSED ({0}) strike {1} -> minimized {2}", reason, count, Describe(hwnd));
            }
        }

        static void RestoreFocus(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);
            keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero);
            SetForegroundWindow(hwnd);
        }

        // EVENT_OBJECT_SHOW: a window just became visible
        static void ShowHandler(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (idObject != 0) return;
            if (!IsConsoleWindow(hwnd)) return;
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            IntPtr fg = GetForegroundWindow();
            if (fg == hwnd) HandleForeground(hwnd);
            else
            {
                bool owned;
                lock (gate) { owned = userOwned.Contains(hwnd); }
                if (owned) return;
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
                return;
            }

            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            POINT p; RECT r;
            GetCursorPos(out p);
            GetWindowRect(hwnd, out r);
            bool cursorInside = p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom;

            if (cursorInside)
            {
                lock (gate) { userOwned.Add(hwnd); }
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
                        bool owned;
                        lock (gate) { owned = userOwned.Contains(h); }
                        if (h == fg || owned) return true;
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
                    if (userOwned.Count > 50 || violations.Count > 50)
                    {
                        var deadU = new List<IntPtr>();
                        foreach (var h in userOwned) if (!IsWindow(h)) deadU.Add(h);
                        foreach (var h in deadU) userOwned.Remove(h);
                        var deadV = new List<IntPtr>();
                        foreach (var kv in violations) if (!IsWindow(kv.Key)) deadV.Add(kv.Key);
                        foreach (var h in deadV) violations.Remove(h);
                    }
                }
            }
            catch { }
        }

        public static void Run(string[] names, string logFile)
        {
            foreach (string n in names) procNames.Add(n);
            logPath = logFile == null ? "" : logFile;
            Log("===== KeepTerminalsBehind v6 started =====");

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

Write-Host "KeepTerminalsBehind v6 (100ms sweep + two-strike suppression) is running." -ForegroundColor Cyan
if ($script:LogPath) { Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray }

[KTB.Hook]::Run($script:ProcNames, $script:LogPath)
