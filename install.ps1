# Installs KeepTerminalsBehind: copies files to a stable location and
# creates a hidden auto-start shortcut named "Keep Terminals Behind".

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:USERPROFILE 'Scripts\keep-terminals-behind'
$startupDir = [Environment]::GetFolderPath('Startup')
$scriptPath = Join-Path $installDir 'KeepTerminalsBehind.ps1'
$shortcutPath = Join-Path $startupDir 'Keep Terminals Behind.lnk'

# Copy files from wherever this install script lives
$sourceDir = $PSScriptRoot
if (-not (Test-Path (Join-Path $sourceDir 'KeepTerminalsBehind.ps1'))) {
    throw "KeepTerminalsBehind.ps1 not found next to install.ps1"
}

New-Item -ItemType Directory -Force -Path $installDir | Out-Null
Copy-Item (Join-Path $sourceDir 'KeepTerminalsBehind.ps1') $scriptPath -Force
Copy-Item (Join-Path $sourceDir 'update.ps1') (Join-Path $installDir 'update.ps1') -Force

# Register a daily auto-update task (runs update.ps1, no admin needed)
try {
    $action  = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$installDir\update.ps1`""
    $trigger = New-ScheduledTaskTrigger -Daily -At '09:00'
    Register-ScheduledTask -TaskName 'KeepTerminalsBehind-Update' -Action $action -Trigger $trigger `
        -Description 'Updates Keep Terminals Behind from GitHub and restarts it if running' `
        -RunLevel Limited -Force | Out-Null
    Write-Host "Daily auto-update task registered: KeepTerminalsBehind-Update" -ForegroundColor Green
} catch {
    Write-Warning "Could not register auto-update task: $_"
}

# Create the startup shortcut
$shell = New-Object -ComObject WScript.Shell
$sc = $shell.CreateShortcut($shortcutPath)
$sc.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$sc.Arguments  = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
$sc.WorkingDirectory = $installDir
$sc.Description = 'Keeps cmd/PowerShell/Terminal windows behind everything else'
$sc.Save()

Write-Host "Installed to: $scriptPath" -ForegroundColor Green
Write-Host "Startup shortcut: $shortcutPath" -ForegroundColor Green
Write-Host ''
Write-Host "Start it now? (Y/n)" -ForegroundColor Cyan
$answer = Read-Host
if ($answer -notmatch '^[Nn]') {
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
        -WindowStyle Hidden
    Write-Host 'Running. Terminal windows will now stay at the back.' -ForegroundColor Green
}
