# Keep Terminals Behind

A tiny Windows background utility that keeps **cmd**, **PowerShell**, and **Windows Terminal** windows at the bottom of the window stack, so console popups from background processes never steal focus or interrupt your workflow.

## The problem

Many Windows apps (dev tools, sync clients, schedulers, AI agents...) silently spawn `cmd` / `powershell` processes. Each one can flash a console window to the **front**, yanking focus away from whatever you're doing.

## The fix

`KeepTerminalsBehind.ps1` is **event-driven**: it registers Windows event hooks (`SetWinEventHook`) and reacts within milliseconds of a console window taking focus or becoming visible — pushing it to the bottom of the Z-order with `SetWindowPos(HWND_BOTTOM)` and handing focus back to the window you were using. A fast 100ms sweep runs as a backstop for consoles that appear or get raised without taking focus.

### Safety rules

- The **foreground window is never touched** — if you deliberately click a terminal, it stays where you put it until you switch away.
- **Minimized** windows are left alone.
- Only console-class windows (`ConsoleWindowClass`, `CASCADIA_HOSTING_WINDOW_CLASS`) or windows owned by `cmd` / `powershell` / `pwsh` / `WindowsTerminal` / `conhost` are managed. Regular apps are never moved.

## Install

Run once from PowerShell:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\install.ps1
```

This copies the script to `C:\Users\<you>\Scripts\keep-terminals-behind\` and creates a shortcut named **"Keep Terminals Behind"** in your Startup folder so it runs (hidden) at every logon.

To run it manually right now:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File .\KeepTerminalsBehind.ps1
```

## Uninstall

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1
```

Removes the Startup shortcut (and stops the running watcher if you pass `-StopRunning`).

## Notes

- A terminal window **you** launch will be suppressed once when it opens — click it once (cursor over the window) and it stays put while you use it.
- Works with classic consoles (`conhost`), pseudo-consoles, and Windows Terminal.
- Newer Windows Terminal versions refuse `SetWindowPos` z-order changes (win32 error 0/1400). In that case the script falls back to **minimize** (1st offense) and **hide** (2nd+ offense) — async, so it can never hang.
- A fast 100ms backstop sweep catches windows that get raised without taking focus.
- Diagnostics are logged to `%TEMP%\KeepTerminalsBehind.log` (disable with `-DisableLog`).

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) — no admin rights, no dependencies

## Options

| Parameter | Default | Description |
|---|---|---|
| `-ProcessNames` | `cmd, powershell, pwsh, WindowsTerminal, conhost` | Process names treated as terminal popups |

## License

MIT
