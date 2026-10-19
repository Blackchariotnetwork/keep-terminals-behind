<#
.SYNOPSIS
  Keeps cmd / PowerShell / Windows Terminal windows at the bottom of the
  window stack so they never interrupt your workflow.

.DESCRIPTION
  Runs quietly in the background. It watches for console windows and:

    - NEWLY SPAWNED console windows that grab focus ("flash" popups) are
      pushed to the bottom of the Z-order and focus is returned to the
      window you were using.
    - Any other visible console window sitting above the bottom is silently
      moved to the back without activating anything.

  Safety rules:
    - A console window you deliberately clicked (already visible, then
      became foreground) is NEVER touched while you're using it.
    - Minimized windows are left alone.
    - Regular windows (browsers, editors, etc.) are never moved.

  To stop it:
    Stop-Process -Id (Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
      Where-Object { $_.CommandLine -match 'KeepTerminalsBehind' }).ProcessId

.EXAMPLE
  powershell.exe -ExecutionPolicy Bypass -File .\KeepTerminalsBehind.ps1
#>

param(
    # Seconds between checks
    [double]$IntervalSeconds = 0.25,
    # Process names treated as "terminal popups" (fallback matching)
    [string[]]$ProcessNames = @('cmd', 'powershell', 'pwsh', 'WindowsTerminal', 'conhost')
)

Add-Type -Name Win -Namespace Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetForegroundWindow();

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint uCmd);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsIconic(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, System.UIntPtr dwExtraInfo);

public delegate bool EnumWindowsProc(System.IntPtr hWnd, System.IntPtr lParam);

[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, System.IntPtr lParam);
"@

# Window classes that are console/terminal windows
$ConsoleClasses = @('ConsoleWindowClass', 'CASCADIA_HOSTING_WINDOW_CLASS')

# HWND_BOTTOM
$HWND_BOTTOM = [IntPtr]::new(6)
# SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE | SWP_NOOWNERZORDER
$SWP_FLAGS = 0x0001 -bor 0x0002 -bor 0x0010 -bor 0x0200
$GW_HWNDLAST = 1
$VK_MENU = 0x12      # ALT key - brief synthetic tap unlocks SetForegroundWindow
$KEYEVENTF_KEYUP = 2

function Test-IsConsoleWindow {
    param([IntPtr]$Hwnd)

    if ($Hwnd -eq [IntPtr]::Zero) { return $false }

    $sb = New-Object System.Text.StringBuilder 256
    [void][Native.Win]::GetClassName($Hwnd, $sb, 256)
    if ($ConsoleClasses -contains $sb.ToString()) { return $true }

    # Fallback: match by owning process name
    $procId = 0
    [void][Native.Win]::GetWindowThreadProcessId($Hwnd, [ref]$procId)
    if ($procId -eq 0) { return $false }
    try {
        $proc = Get-Process -Id $procId -ErrorAction Stop
        return ($ProcessNames -contains $proc.ProcessName)
    } catch { return $false }
}

function Get-AllWindows {
    $list = New-Object System.Collections.Generic.List[IntPtr]
    $callback = [Native.Win+EnumWindowsProc]{
        param([IntPtr]$h, [IntPtr]$l)
        $list.Add($h)
        return $true
    }
    [void][Native.Win]::EnumWindows($callback, [IntPtr]::Zero)
    return $list
}

function Restore-Focus {
    # Background processes are normally blocked from setting focus.
    # A synthetic ALT tap unlocks SetForegroundWindow for a moment.
    param([IntPtr]$Hwnd)
    if ($Hwnd -eq [IntPtr]::Zero) { return }
    [void][Native.Win]::keybd_event($VK_MENU, 0, 0, [System.UIntPtr]::Zero)
    [void][Native.Win]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, [System.UIntPtr]::Zero)
    [void][Native.Win]::SetForegroundWindow($Hwnd)
}

Write-Host "KeepTerminalsBehind v2 is running. Console flash-popups will be suppressed." -ForegroundColor Cyan
Write-Host "Press Ctrl+C to stop." -ForegroundColor DarkGray

# hwnd -> was it visible last tick?
$known = @{}
# The last window the user was genuinely working in (non-console foreground)
$lastGood = [IntPtr]::Zero

while ($true) {
    try {
        $fg = [Native.Win]::GetForegroundWindow()
        $fgIsConsole = Test-IsConsoleWindow -Hwnd $fg

        if ($fg -ne [IntPtr]::Zero -and -not $fgIsConsole) {
            $lastGood = $fg
        }

        foreach ($hwnd in (Get-AllWindows)) {
            $visible = [Native.Win]::IsWindowVisible($hwnd)
            $wasVisible = if ($known.ContainsKey($hwnd)) { $known[$hwnd] } else { $false }

            if ($visible -and -not [Native.Win]::IsIconic($hwnd) -and (Test-IsConsoleWindow -Hwnd $hwnd)) {

                if ($hwnd -eq $fg) {
                    if (-not $fgIsConsole) { throw 'unreachable' }

                    if ($hwnd -eq $lastGood) {
                        # User is deliberately using this console - leave it alone
                    }
                    elseif ($lastGood -ne [IntPtr]::Zero -and -not $wasVisible) {
                        # A console that just spawned (or just re-appeared) grabbed
                        # focus. Push it behind and give focus back to the user.
                        [void][Native.Win]::SetWindowPos($hwnd, $HWND_BOTTOM, 0, 0, 0, 0, $SWP_FLAGS)
                        Restore-Focus -Hwnd $lastGood
                    }
                    # (if it was already visible before becoming foreground, the
                    #  user alt-tabbed / clicked it on purpose -> leave it)
                }
                else {
                    # Visible, non-foreground console window: keep it at the back.
                    # Only move it if it isn't already at the very bottom.
                    $bottom = [Native.Win]::GetWindow($hwnd, $GW_HWNDLAST)
                    if ($bottom -ne [IntPtr]::Zero -and $bottom -ne $hwnd) {
                        [void][Native.Win]::SetWindowPos($hwnd, $HWND_BOTTOM, 0, 0, 0, 0, $SWP_FLAGS)
                    }
                }
            }

            $known[$hwnd] = $visible
        }

        # Occasionally prune dead hwnds from tracking
        if ($known.Count -gt 400) {
            $dead = @($known.Keys | Where-Object { $null -eq $_ -or $_ -eq [IntPtr]::Zero })
            foreach ($d in $dead) { $known.Remove($d) }
        }
    } catch {
        # Keep running even if something odd happens mid-loop
    }

    Start-Sleep -Milliseconds ([int]($IntervalSeconds * 1000))
}
