<#
.SYNOPSIS
  Keeps cmd / PowerShell / Windows Terminal windows at the bottom of the
  window stack so they never interrupt your workflow.

.DESCRIPTION
  v4 - EVENT-DRIVEN with cursor-based intent detection.

  Registers Windows event hooks (SetWinEventHook) and reacts within
  milliseconds of a console window taking focus (EVENT_SYSTEM_FOREGROUND)
  or becoming visible (EVENT_OBJECT_SHOW):

    - If the MOUSE CURSOR is over the console window when it takes focus,
      the user put it there on purpose -> left alone.
    - Otherwise it is a script-spawned popup -> pushed to the bottom of the
      Z-order and focus is returned to the window you were using.

  A lightweight 1-second sweep runs as a backstop.

  DIAGNOSTICS: every decision is logged to %TEMP%\KeepTerminalsBehind.log
  (disable with -DisableLog). SetWindowPos failures (e.g. elevated windows
  that a normal-privilege process may not reorder) are logged too.

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
        [DllImport("user32.dll", SetLastError = true)] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
        [DllImport("user32.dll")] public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);
        [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
        [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);
        [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);
        [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

        const int SW_MINIMIZE = 6;
        const uint WM_SYSCOMMAND = 0x0112;
        const uint SC_MINIMIZE = 0xF020;
        [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
        [DllImport("user32.dll")] static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
        [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG lpMsg);
        [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG lpMsg);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT lpPoint);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

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
        const byte VK_MENU = 0x12; // ALT
        const uint KEYEVENTF_KEYUP = 2;

        static readonly string[] ConsoleClasses = new string[] { "ConsoleWindowClass", "CASCADIA_HOSTING_WINDOW_CLASS" };
        static HashSet<string> procNames = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        // ---------- state ----------
        static readonly object gate = new object();
        static IntPtr lastGood = IntPtr.Zero;
        static string logPath = "";
        static WinEventDelegate fgHandler;   // keep delegates alive (GC)
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

        static bool PushBottom(IntPtr hwnd)
        {
            bool ok = SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_FLAGS);
            if (ok) return true;

            // Fallback: SetWindowPos is refused for some window hosts (e.g. newer
            // Windows Terminal windows). A minimized popup can't cover your work.
            // ShowWindowAsync/PostMessage are async so they can never hang us.
            int err = Marshal.GetLastWin32Error();
            Log("PUSH FAILED win32error={1} {0} - trying minimize fallback", Describe(hwnd), err);
            bool min1 = ShowWindowAsync(hwnd, SW_MINIMIZE);
            if (!min1)
            {
                Log("ShowWindowAsync failed - posting SC_MINIMIZE to {0}", Describe(hwnd));
                PostMessage(hwnd, WM_SYSCOMMAND, (IntPtr)SC_MINIMIZE, IntPtr.Zero);
            }
            Log("MINIMIZED (fallback) {0}", Describe(hwnd));
            return false;
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
            if (idObject != 0) return; // only OBJID_WINDOW
            if (!IsConsoleWindow(hwnd)) return;
            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            IntPtr fg = GetForegroundWindow();
            if (fg == hwnd) HandleForeground(hwnd);
            else { PushBottom(hwnd); Log("SHOW -> pushed {0}", Describe(hwnd)); }
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
                Log("FG -> normal window {0}", Describe(hwnd));
                return;
            }

            if (!IsWindowVisible(hwnd) || IsIconic(hwnd)) return;

            // Cursor-based intent: if the mouse is over the console window,
            // the user put it in front on purpose -> leave it alone.
            POINT p; RECT r;
            GetCursorPos(out p);
            GetWindowRect(hwnd, out r);
            bool cursorInside = p.X >= r.Left && p.X < r.Right && p.Y >= r.Top && p.Y < r.Bottom;

            if (cursorInside)
            {
                Log("FG -> console {0} CURSOR INSIDE - leaving alone", Describe(hwnd));
                return;
            }

            if (hwnd == lastGood) return;

            if (lastGood != IntPtr.Zero)
            {
                Log("FG -> console {0} POPUP - pushing behind + restoring focus", Describe(hwnd));
                PushBottom(hwnd);
                RestoreFocus(lastGood);
            }
            else
            {
                Log("FG -> console {0} POPUP (no lastGood) - pushing behind", Describe(hwnd));
                PushBottom(hwnd);
            }
        }

        // Backstop sweep
        static void Backstop(object state)
        {
            try
            {
                IntPtr fg = GetForegroundWindow();

                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    if (IsWindowVisible(h) && !IsIconic(h) && IsConsoleWindow(h))
                    {
                        if (h != fg && !IsAtBottom(h))
                        {
                            if (PushBottom(h)) Log("SWEEP -> pushed {0}", Describe(h));
                        }
                    }
                    return true;
                }, IntPtr.Zero);

                if (fg != IntPtr.Zero && !IsConsoleWindow(fg))
                {
                    lock (gate) { lastGood = fg; }
                }
            }
            catch { }
        }

        public static void Run(string[] names, string logFile)
        {
            foreach (string n in names) procNames.Add(n);
            logPath = logFile == null ? "" : logFile;
            Log("===== KeepTerminalsBehind v4 started =====");

            fgHandler = new WinEventDelegate(FgHandler);
            showHandler = new WinEventDelegate(ShowHandler);

            IntPtr h1 = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, fgHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            IntPtr h2 = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, showHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            Log("hooks: fg=0x{0} show=0x{1}", h1.ToString("X"), h2.ToString("X"));
            if (h1 == IntPtr.Zero && h2 == IntPtr.Zero) Log("WARNING: no hooks registered!");

            var backstop = new System.Threading.Timer(Backstop, null, 1000, 1000);

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

Write-Host "KeepTerminalsBehind v4 (event-driven + cursor intent) is running." -ForegroundColor Cyan
if ($script:LogPath) { Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray }

[KTB.Hook]::Run($script:ProcNames, $script:LogPath)
