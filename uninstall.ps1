#Requires -Version 5.1
<#
    Talkey - kaldirici.

    Kullanım:  sağ tık -> "Run with PowerShell"
    veya:      powershell -ExecutionPolicy Bypass -File uninstall.ps1
#>
$ErrorActionPreference = 'Continue'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$Dest = Join-Path $env:LOCALAPPDATA 'Talkey'
$startup = [Environment]::GetFolderPath('Startup')

Write-Host ""
Write-Host "==> Calisan surecler durduruluyor" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name = 'pythonw.exe' OR Name = 'python.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dictate-daemon.py*' -or $_.CommandLine -like '*dictate-record.py*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*dictate.ahk*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

Write-Host "==> Baslangic kisayollari siliniyor" -ForegroundColor Cyan
foreach ($lnk in @('Talkey.lnk', 'Talkey Daemon.lnk')) {
    $p = Join-Path $startup $lnk
    if (Test-Path $p) { Remove-Item $p -Force; Write-Host "    silindi: $p" -ForegroundColor DarkGray }
}

Write-Host "==> Gecici dosyalar siliniyor" -ForegroundColor Cyan
$work = Join-Path $env:TEMP 'talkey'
if (Test-Path $work) { Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue }

$answer = Read-Host "    Kurulum klasoru de silinsin mi? ($Dest) [e/H]"
if ($answer -match '^[eEyY]') {
    # Kendi içinden çalışıyor olabiliriz; klasörü kapanışta silmesi için ayrı bir
    # PowerShell bırakıyoruz, yoksa venv kilitli kalıp silme yarım kalıyor.
    Start-Process powershell -ArgumentList @(
        '-NoProfile', '-WindowStyle', 'Hidden', '-Command',
        "Start-Sleep -Seconds 3; Remove-Item -LiteralPath '$Dest' -Recurse -Force -ErrorAction SilentlyContinue"
    )
    Write-Host "    silinecek: $Dest" -ForegroundColor DarkGray
}

$answer = Read-Host "    Indirilen whisper modelleri de silinsin mi? (~1.5 GB) [e/H]"
if ($answer -match '^[eEyY]') {
    $hub = Join-Path $env:USERPROFILE '.cache\huggingface\hub'
    if (Test-Path $hub) {
        Get-ChildItem $hub -Directory -Filter '*faster-whisper*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                Write-Host "    silindi: $($_.Name)" -ForegroundColor DarkGray
            }
    }
}

Write-Host ""
Write-Host "  Kaldirma tamam. Python ve AutoHotkey dokunulmadan birakildi." -ForegroundColor Green
Write-Host ""
Read-Host "  Kapatmak icin Enter"
