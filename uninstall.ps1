#Requires -Version 5.1
<#
    Talkey uninstaller.

    Usage:  right-click -> "Run with PowerShell"
    or:     powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Dest = Join-Path $env:LOCALAPPDATA 'Talkey'
$startup = [Environment]::GetFolderPath('Startup')

Write-Host ""
Write-Host "==> Stopping running processes" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dictate-daemon.py*' -or $_.CommandLine -like '*dictate-record.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dictate.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "==> Removing startup shortcuts" -ForegroundColor Cyan
foreach ($lnk in @('Talkey.lnk', 'Talkey Daemon.lnk')) {
    $p = Join-Path $startup $lnk
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "    removed: $p" -ForegroundColor DarkGray }
}

Write-Host "==> Clearing temporary files" -ForegroundColor Cyan
$work = Join-Path $env:TEMP 'talkey'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

$answer = Read-Host "    Delete the install folder too? ($Dest) [y/N]"
if ($answer -match '^[yY]') {
    # This script may be running from inside that folder, and the venv keeps files
    # locked, so hand the delete to a separate PowerShell that waits for us to exit.
    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
        "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$Dest' -Recurse -Force -ErrorAction SilentlyContinue"
    )
    Write-Host "    scheduled for deletion: $Dest" -ForegroundColor DarkGray
}

$answer = Read-Host "    Delete the downloaded whisper models too? (~1.5 GB) [y/N]"
if ($answer -match '^[yY]') {
    $hub = Join-Path $env:USERPROFILE '.cache\huggingface\hub'
    if (Test-Path $hub) {
        Get-ChildItem $hub -Directory -Filter '*faster-whisper*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    removed: $($_.Name)" -ForegroundColor DarkGray
            }
    }
}

Write-Host ""
Write-Host "  Done. Python and AutoHotkey were left installed." -ForegroundColor Green
Write-Host ""
Read-Host "  Press Enter to close"
