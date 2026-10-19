# Keep Terminals Behind

A tiny Windows background utility that keeps **cmd**, **PowerShell**, and **Windows Terminal** windows at the bottom of the window stack, so console popups from background processes never steal focus or interrupt your workflow.

## The problem

Many Windows apps (dev tools, sync clients, schedulers, AI agents...) silently spawn `cmd` / `powershell` processes. Each one can flash a console window to the **front**, yanking focus away from whatever you're doing.

## The fix

`KeepTerminalsBehind.ps1` is **event-driven**: it registers Windows event hooks (`SetWinEventHook`) and reacts within milliseconds of a console window taking focus or becoming visible — pushing it to the bottom of the Z-order with `SetWindowPos(HWND_BOTTOM)` and handing focus back to the window you were using. A lightweight 1-second sweep runs as a backstop for consoles that appear without taking focus.

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

- A terminal window **you** launch will be pushed to the back once when it opens — click it once and it stays put while you use it.
- Works with classic consoles (`conhost`) and Windows Terminal.

## Requirements

- Windows 10 / 11
- Windows PowerShell 5.1 (built in) — no admin rights, no dependencies

## Options

| Parameter | Default | Description |
|---|---|---|
| `-ProcessNames` | `cmd, powershell, pwsh, WindowsTerminal, conhost` | Process names treated as terminal popups |

## License

MIT
