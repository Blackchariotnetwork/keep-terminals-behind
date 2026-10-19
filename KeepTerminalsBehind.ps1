<#
.SYNOPSIS
  Keeps cmd / PowerShell / Windows Terminal windows at the bottom of the
  window stack so they never interrupt your workflow.

.DESCRIPTION
  v3 - EVENT-DRIVEN. Instead of polling, it registers Windows event hooks
  (SetWinEventHook) and reacts within milliseconds of a console window:

    - taking focus (EVENT_SYSTEM_FOREGROUND)  -> pushed to the bottom and
      focus is returned to the window you were using
    - becoming visible (EVENT_OBJECT_SHOW)    -> pushed to the bottom

  A lightweight 1s polling sweep runs as a backstop for anything the hooks
  miss (e.g. consoles that appear without taking focus).

  Safety rules:
    - A console you deliberately clicked (already visible, then became
      foreground) is NEVER touched while you're using it.
    - Minimized windows are left alone.
    - Regular windows (browsers, editors, etc.) are never moved.

  Note: a terminal window YOU launch will be pushed to the back once when
  it opens; just click it once and it will stay put while you use it.

  To stop it:
    Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -match 'KeepTerminalsBehind' } |
      ForEach-Object { Stop-Process -Id $_.ProcessId }

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\KeepTerminalsBehind.ps1
#>

param(
    [string[]]$ProcessNames = @('cmd', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost')
)

$script:ProcNames = $ProcessNames

Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace KTB
{
    public static class Hook
    {
        // ---------- Win32 ----------
        delegate void WinEventDelegate(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate pfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
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

        struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public int pt_x; public int pt_y; }

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
        static readonly HashSet<IntPtr> knownVisible = new HashSet<IntPtr>();
        static IntPtr lastGood = IntPtr.Zero;
        static WinEventDelegate fgHandler;   // keep delegates alive (GC)
        static WinEventDelegate showHandler;

        static bool IsConsoleWindow(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return false;
            var sb = new System.Text.StringBuilder(256);
            GetClassName(hwnd, sb, 256);
            string cls = sb.ToString();
            foreach (string c in ConsoleClasses) if (cls == c) return true;

            // Fallback: owning process name
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

        static void PushBottom(IntPtr hwnd)
        {
            SetWindowPos(hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_FLAGS);
        }

        static void RestoreFocus(IntPtr hwnd)
        {
            if (hwnd == IntPtr.Zero) return;
            keybd_event(VK_MENU, 0, 0, UIntPtr.Zero);          // synthetic ALT tap unlocks
            keybd_event(VK_MENU, 0, KEYEVENTF_KEYUP, UIntPtr.Zero); // SetForegroundWindow
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
            else PushBottom(hwnd);
        }

        // EVENT_SYSTEM_FOREGROUND: the foreground window changed
        static void FgHandler(IntPtr hHook, uint eventId, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
        {
            if (idObject != 0 || idChild != 0) return; // only OBJID_WINDOW / index 0
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
            if (hwnd == lastGood) return; // user is deliberately using it

            bool wasVisible;
            lock (gate) { wasVisible = knownVisible.Contains(hwnd); }

            // Suppress only flash popups: consoles that just spawned/re-appeared
            // and grabbed focus. Consoles the user clicked (already visible)
            // are left alone.
            if (!wasVisible && lastGood != IntPtr.Zero)
            {
                PushBottom(hwnd);
                RestoreFocus(lastGood);
            }
        }

        // Backstop sweep: every second, send any visible non-foreground
        // console window to the bottom and refresh visibility tracking.
        static void Backstop(object state)
        {
            try
            {
                IntPtr fg = GetForegroundWindow();
                var visibleConsoles = new HashSet<IntPtr>();

                EnumWindows(delegate(IntPtr h, IntPtr l)
                {
                    if (IsWindowVisible(h) && !IsIconic(h) && IsConsoleWindow(h))
                    {
                        visibleConsoles.Add(h);
                        if (h != fg && !IsAtBottom(h)) PushBottom(h);
                    }
                    return true;
                }, IntPtr.Zero);

                lock (gate)
                {
                    knownVisible.Clear();
                    foreach (IntPtr h in visibleConsoles) knownVisible.Add(h);
                    if (fg != IntPtr.Zero && !IsConsoleWindow(fg)) lastGood = fg;
                }
            }
            catch { }
        }

        public static void Run(string[] names)
        {
            foreach (string n in names) procNames.Add(n);

            fgHandler = new WinEventDelegate(FgHandler);
            showHandler = new WinEventDelegate(ShowHandler);

            SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, IntPtr.Zero, fgHandler, 0, 0, WINEVENT_OUTOFCONTEXT);
            SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, showHandler, 0, 0, WINEVENT_OUTOFCONTEXT);

            var backstop = new System.Threading.Timer(Backstop, null, 1000, 1000);

            // Message pump required for the hooks to deliver events
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

Write-Host "KeepTerminalsBehind v3 (event-driven) is running." -ForegroundColor Cyan
Write-Host "Console flash-popups are suppressed in real time. Press Ctrl+C to stop." -ForegroundColor DarkGray

[KTB.Hook]::Run($script:ProcNames)
