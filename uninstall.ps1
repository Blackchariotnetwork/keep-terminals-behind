# Removes the "Keep Terminals Behind" startup shortcut.
# Usage: powershell.exe -ExecutionPolicy Bypass -File .\uninstall.ps1 [-StopRunning]

param(
    [switch]$StopRunning
)

$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir 'Keep Terminals Behind.lnk'

if (Test-Path $shortcutPath) {
    Remove-Item $shortcutPath -Force
    Write-Host "Removed startup shortcut: $shortcutPath" -ForegroundColor Green
} else {
    Write-Host 'No startup shortcut found (already removed?).' -ForegroundColor Yellow
}

if ($StopRunning) {
    # Stop watcher instances started from the installed location
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like '*KeepTerminalsBehind.ps1*' } |
        ForEach-Object {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Host "Stopped watcher (PID $($_.ProcessId))" -ForegroundColor Green
        }
}
