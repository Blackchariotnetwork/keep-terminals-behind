# Updates the installed copy of KeepTerminalsBehind from GitHub and
# restarts the watcher if (and only if) it is currently running.
# Intended to be run by a scheduled task; safe to run manually too.

$ErrorActionPreference = 'Stop'

$repoUrl   = 'https://github.com/Blackchariotnetwork/keep-terminals-behind.git'
$installDir = Join-Path $env:USERPROFILE 'Scripts\keep-terminals-behind'
$scriptPath = Join-Path $installDir 'KeepTerminalsBehind.ps1'

if (-not (Test-Path $installDir)) {
    Write-Warning "Not installed ($installDir missing). Run install.ps1 first."
    exit 1
}

# Fetch latest from GitHub (git if available, otherwise a zip download)
$tmp = Join-Path $env:TEMP ("ktb-update-" + [guid]::NewGuid().ToString('N'))
$git = Get-Command git -ErrorAction SilentlyContinue

try {
    if ($git) {
        git clone --depth 1 --quiet $repoUrl $tmp 2>$null
    } else {
        $zip = "$tmp.zip"
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://github.com/Blackchariotnetwork/keep-terminals-behind/archive/refs/heads/main.zip' -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $tmp -Force
        $tmp = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    }

    $newScript = Join-Path $tmp 'KeepTerminalsBehind.ps1'
    if (-not (Test-Path $newScript)) { throw "Could not fetch latest KeepTerminalsBehind.ps1 from GitHub" }

    $old = Get-FileHash $scriptPath -ErrorAction SilentlyContinue
    $new = Get-FileHash $newScript

    if (-not $old -or $old.Hash -ne $new.Hash) {
        Copy-Item $newScript $scriptPath -Force
        Copy-Item (Join-Path $tmp 'install.ps1')   (Join-Path $installDir 'install.ps1')   -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $tmp 'uninstall.ps1') (Join-Path $installDir 'uninstall.ps1') -Force -ErrorAction SilentlyContinue
        Copy-Item (Join-Path $tmp 'update.ps1')    (Join-Path $installDir 'update.ps1')    -Force -ErrorAction SilentlyContinue
        $updated = $true
    } else {
        $updated = $false
    }
} finally {
    if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

# Restart the watcher ONLY if it is running (so a deliberate stop is respected)
$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'KeepTerminalsBehind.ps1' }

if ($updated -and $running) {
    $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`"" `
        -WindowStyle Hidden
    Write-Host "Updated and restarted the watcher." -ForegroundColor Green
} elseif ($updated) {
    Write-Host "Updated. Watcher was not running, so it was not started." -ForegroundColor Green
} else {
    Write-Host "Already up to date." -ForegroundColor DarkGray
}
