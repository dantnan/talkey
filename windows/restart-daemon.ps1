#Requires -Version 5.1
# Talkey - stop any running whisper daemon and start a fresh one.
$ErrorActionPreference = 'SilentlyContinue'

$dir = $PSScriptRoot
if (-not $dir) { $dir = Split-Path -Parent $MyInvocation.MyCommand.Path }

Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" |
    Where-Object { $_.CommandLine -like '*talkey-daemon.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Start-Sleep -Milliseconds 500

$pythonw = Join-Path $dir 'venv\Scripts\pythonw.exe'
Start-Process -FilePath $pythonw `
    -ArgumentList ('"{0}"' -f (Join-Path $dir 'talkey-daemon.py')) `
    -WorkingDirectory $dir -WindowStyle Hidden
