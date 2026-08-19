#Requires -Version 5.1
<#
    Talkey - Windows kurucu.

    Kullanım:  sağ tık -> "Run with PowerShell"
    veya:      powershell -ExecutionPolicy Bypass -File install.ps1

    Yaptıkları:
      1. Python 3 ve AutoHotkey v2 yoksa winget ile kurar
      2. %LOCALAPPDATA%\Talkey içine dosyaları kopyalar
      3. İzole bir venv açıp faster-whisper + sounddevice kurar
      4. Mikrofonu ve modeli sorar, config.ini yazar
      5. Modeli indirir (ilk seferde ~1.5 GB)
      6. Başlangıç klasörüne kısayolları koyar ve sistemi başlatır

    Yönetici hakkı gerekmez.
#>
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$env:PYTHONIOENCODING = 'utf-8'

$Src = $PSScriptRoot
if (-not $Src) { $Src = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Dest = Join-Path $env:LOCALAPPDATA 'Talkey'
$Files = @(
    'dictate.ahk',
    'dictate-daemon.py',
    'dictate-client.py',
    'dictate-record.py',
    'talkey_cfg.py',
    'restart-daemon.ps1',
    'uninstall.ps1',
    'README.md'
)

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host ""; Write-Host "HATA: $msg" -ForegroundColor Red; Read-Host "  Kapatmak icin Enter"; exit 1 }

# pip ve winget normal calisirken bile stderr'e yazar; $ErrorActionPreference
# 'Stop' iken bu, PowerShell 5.1'de kurulumu ortasindan keser. Harici komutlari
# hep buradan cagirip basariyi $LASTEXITCODE ile olcuyoruz.
function Invoke-Native {
    $exe = $args[0]
    $rest = @()
    if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @rest
    } catch {
        # Program yok ya da calistirilamadi. Bunu firlatirsak kurulum ortasindan
        # kesilir; cagiran taraf zaten cikis kodunu kontrol ediyor.
        $global:LASTEXITCODE = 127
    } finally {
        $ErrorActionPreference = $old
    }
}

function Refresh-EnvPath {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $env:Path = ($machine, $user | Where-Object { $_ }) -join ';'
}

function Test-PythonExe($exe) {
    if (-not $exe) { return $false }
    # Microsoft Store'un "python.exe" kisayolu burada sifir disi kod dondurur,
    # gercek yorumlayiciyi sahtesinden ayiran sey bu.
    $ver = Invoke-Native $exe '-c' "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $ver) { return $false }
    try { return ([version]("$ver".Trim()) -ge [version]'3.9') } catch { return $false }
}

function Get-PythonExe {
    $candidates = New-Object System.Collections.ArrayList
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $found = Invoke-Native 'py' '-3' '-c' 'import sys; print(sys.executable)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $found) { [void]$candidates.Add("$found".Trim()) }
    }
    foreach ($cmd in @('python', 'python3')) {
        $resolved = Get-Command $cmd -ErrorAction SilentlyContinue
        if ($resolved) { [void]$candidates.Add($resolved.Source) }
    }
    # winget kurulumundan hemen sonra PATH henuz yenilenmemis olabiliyor.
    foreach ($root in @((Join-Path $env:LOCALAPPDATA 'Programs\Python'), $env:ProgramFiles)) {
        if ($root -and (Test-Path $root)) {
            Get-ChildItem $root -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                Sort-Object Name -Descending |
                ForEach-Object {
                    $exe = Join-Path $_.FullName 'python.exe'
                    if (Test-Path $exe) { [void]$candidates.Add($exe) }
                }
        }
    }
    foreach ($exe in $candidates) { if (Test-PythonExe $exe) { return $exe } }
    return $null
}

function Get-AhkExe {
    $roots = @($env:ProgramFiles, ${env:ProgramFiles(x86)}, (Join-Path $env:LOCALAPPDATA 'Programs')) |
        Where-Object { $_ }
    $suffixes = @('AutoHotkey\v2\AutoHotkey64.exe', 'AutoHotkey\AutoHotkey64.exe')
    foreach ($root in $roots) {
        foreach ($suffix in $suffixes) {
            $p = Join-Path $root $suffix
            if (Test-Path $p) { return $p }
        }
    }
    $onPath = Get-Command AutoHotkey64.exe -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $root = Join-Path $env:ProgramFiles 'AutoHotkey'
    if (Test-Path $root) {
        $hit = Get-ChildItem $root -Filter 'AutoHotkey64.exe' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function Install-WithWinget($id, $label) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Die "$label kurulu degil ve winget bulunamadi. Microsoft Store'dan 'App Installer' kurun, sonra bu betigi tekrar calistirin."
    }
    Info "$label kuruluyor (winget: $id)..."
    Invoke-Native 'winget' 'install' '-e' '--id' $id '--accept-package-agreements' '--accept-source-agreements' '--scope' 'user'
    if ($LASTEXITCODE -ne 0) {
        Info "Kullanici kapsaminda kurulamadi, makine kapsami deneniyor..."
        Invoke-Native 'winget' 'install' '-e' '--id' $id '--accept-package-agreements' '--accept-source-agreements'
    }
    Refresh-EnvPath
}

function New-Shortcut($linkPath, $target, $arguments, $workDir) {
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($linkPath)
    $sc.TargetPath = $target
    $sc.Arguments = $arguments
    $sc.WorkingDirectory = $workDir
    $sc.Save()
}

# ---------------------------------------------------------------- 0. hazırlık
Write-Host ""
Write-Host "  Talkey - konusmayi yaziya ceviren kisayol (F8 / F9)" -ForegroundColor White
Write-Host "  Kurulum klasoru: $Dest" -ForegroundColor DarkGray

Get-ChildItem $Src -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

foreach ($f in $Files) {
    if (-not (Test-Path (Join-Path $Src $f))) { Die "Pakette eksik dosya: $f" }
}

# ---------------------------------------------------------------- 1. bağımlılıklar
Step "Python araniyor"
$python = Get-PythonExe
if (-not $python) {
    Install-WithWinget 'Python.Python.3.12' 'Python 3.12'
    $python = Get-PythonExe
    if (-not $python) { Die "Python kuruldu ama bulunamadi. Bilgisayari yeniden baslatip tekrar deneyin." }
}
Info "Python: $python"

Step "AutoHotkey v2 araniyor"
$ahk = Get-AhkExe
if (-not $ahk) {
    Install-WithWinget 'AutoHotkey.AutoHotkey' 'AutoHotkey v2'
    $ahk = Get-AhkExe
    if (-not $ahk) { Die "AutoHotkey kuruldu ama AutoHotkey64.exe bulunamadi." }
}
Info "AutoHotkey: $ahk"

# ---------------------------------------------------------------- 2. dosyalar
Step "Dosyalar kopyalaniyor"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
if ((Resolve-Path $Src).Path -ne (Resolve-Path $Dest).Path) {
    foreach ($f in $Files) { Copy-Item (Join-Path $Src $f) $Dest -Force }
}
Info "$($Files.Count) dosya -> $Dest"

# ---------------------------------------------------------------- 3. venv
$venv = Join-Path $Dest 'venv'
$venvPy = Join-Path $venv 'Scripts\python.exe'
$venvPyw = Join-Path $venv 'Scripts\pythonw.exe'

Step "Python ortami hazirlaniyor (birkac dakika surebilir)"
if (-not (Test-Path $venvPy)) {
    Invoke-Native $python '-m' 'venv' $venv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPy)) { Die "venv olusturulamadi." }
}
Invoke-Native $venvPy '-m' 'pip' 'install' '--upgrade' 'pip' '--quiet'
Invoke-Native $venvPy '-m' 'pip' 'install' '--upgrade' 'faster-whisper' 'sounddevice'
if ($LASTEXITCODE -ne 0) { Die "faster-whisper / sounddevice kurulamadi. Internet baglantisini kontrol edin." }
Info "faster-whisper + sounddevice hazir"

# ---------------------------------------------------------------- 4. mikrofon
Step "Mikrofon secimi"
$raw = Invoke-Native $venvPy (Join-Path $Dest 'dictate-record.py') '--list'
$mics = @()
foreach ($line in $raw) {
    $parts = "$line".Split("`t")
    if ($parts.Count -ge 2) { $mics += [pscustomobject]@{ Index = $parts[0]; Name = $parts[1] } }
}
if ($mics.Count -eq 0) {
    Warn "Giris cihazi listelenemedi, Windows varsayilan mikrofonu kullanilacak."
    $micValue = ''
} else {
    Write-Host "     0) Windows varsayilan mikrofonu (onerilen)"
    for ($i = 0; $i -lt $mics.Count; $i++) {
        Write-Host ("    {0,2}) {1}" -f ($i + 1), $mics[$i].Name)
    }
    $pick = Read-Host "    Secim (Enter = 0)"
    if ([string]::IsNullOrWhiteSpace($pick) -or "$pick".Trim() -eq '0') {
        $micValue = ''
    } else {
        $n = 0
        if ([int]::TryParse("$pick".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $mics.Count) {
            $micValue = $mics[$n - 1].Name
        } else {
            Warn "Gecersiz secim, varsayilan mikrofon kullanilacak."
            $micValue = ''
        }
    }
}

# ---------------------------------------------------------------- 5. model
Step "Model secimi"
Write-Host "     1) small     - en hizli, dogruluk orta       (~0.5 GB)"
Write-Host "     2) medium    - onerilen denge                (~1.5 GB)"
Write-Host "     3) large-v3  - en dogru, CPU'da cok yavas    (~3 GB)"
$pick = Read-Host "    Secim (Enter = 2)"
switch ("$pick".Trim()) {
    '1' { $model = 'small' }
    '3' { $model = 'large-v3' }
    default { $model = 'medium' }
}
Info "Model: $model"

Step "GPU denetleniyor"
$compute = 'cpu'
$gpuCount = Invoke-Native $venvPy '-c' 'import ctranslate2; print(ctranslate2.get_cuda_device_count())' 2>$null
if ($LASTEXITCODE -eq 0 -and "$gpuCount".Trim() -ne '' -and "$gpuCount".Trim() -ne '0') {
    Info "CUDA cihazi gorundu, gercekten calisiyor mu diye kucuk bir model deneniyor..."
    # get_cuda_device_count() sadece sürücüyü görür; cuBLAS/cuDNN eksikse model
    # yüklemesi patlar. GPU'yu varsaymak yerine burada gerçekten deniyoruz.
    Invoke-Native $venvPy '-c' "from faster_whisper import WhisperModel; WhisperModel('tiny', device='cuda', compute_type='float16')" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $compute = 'cuda:float16'
        Info "GPU kullanilacak (cuda/float16)"
    } else {
        Warn "GPU var ama cuBLAS/cuDNN eksik gorunuyor; CPU kullanilacak."
    }
} else {
    Info "GPU yok, CPU kullanilacak (cpu/int8)"
}

# ---------------------------------------------------------------- 6. config
Step "config.ini yaziliyor"
$cfg = @"
; Talkey ayarlari. Degistirtalkeyn sonra:
;   - [whisper] veya [daemon] degistiyse: tepsi menusu > "Daemon'i yeniden baslat"
;   - [hotkeys], [lang] veya [audio] degistiyse: tepsi menusu > Cikis, sonra Talkey'yi tekrar baslat

[audio]
; Bos = Windows varsayilan mikrofonu. Cihaz adinin bir parcasi da yeterli.
device = $micValue
; Tusa tekrar basmayi unutursaniz kayit bu kadar saniye sonra kendi durur.
max_seconds = 600

[whisper]
model = $model
; auto | cpu | cuda | cuda:float16 | cpu:int8
compute = $compute
beam_size = 5

[lang]
primary = tr
secondary = en

[hotkeys]
primary = F8
secondary = F9

[daemon]
host = 127.0.0.1
port = 47353
; Model bu kadar saniye kullanilmazsa RAM'den dusurulur.
idle_unload = 600
startup_timeout = 300
"@
[IO.File]::WriteAllText((Join-Path $Dest 'config.ini'), $cfg, (New-Object System.Text.UTF8Encoding($false)))
Info "$Dest\config.ini"

# ---------------------------------------------------------------- 7. model indir
Step "Model indiriliyor ve deneniyor (ilk seferde uzun surer)"
Push-Location $Dest
Invoke-Native $venvPy '-c' "import talkey_cfg; from faster_whisper import WhisperModel; cfg = talkey_cfg.load(); d, c = talkey_cfg.resolve_compute(cfg.get('whisper', 'compute')); WhisperModel(cfg.get('whisper', 'model'), device=d, compute_type=c); print('model ok')"
$modelOk = ($LASTEXITCODE -eq 0)
Pop-Location
if (-not $modelOk) { Die "Model yuklenemedi. Internet baglantisini kontrol edip tekrar deneyin." }

# ---------------------------------------------------------------- 8. başlangıç
Step "Baslangica ekleniyor"
$startup = [Environment]::GetFolderPath('Startup')
New-Shortcut (Join-Path $startup 'Talkey.lnk') $ahk ('"{0}"' -f (Join-Path $Dest 'dictate.ahk')) $Dest
New-Shortcut (Join-Path $startup 'Talkey Daemon.lnk') $venvPyw ('"{0}"' -f (Join-Path $Dest 'dictate-daemon.py')) $Dest
Info "$startup\Talkey.lnk"
Info "$startup\Talkey Daemon.lnk"

# ---------------------------------------------------------------- 9. çalıştır
Step "Baslatiliyor"
Invoke-Native 'powershell' '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $Dest 'restart-daemon.ps1')
Start-Process -FilePath $ahk -ArgumentList ('"{0}"' -f (Join-Path $Dest 'dictate.ahk')) -WorkingDirectory $Dest

Write-Host ""
Write-Host "  Kurulum tamam." -ForegroundColor Green
Write-Host ""
Write-Host "  F8 bas -> konus -> F8 bas   ->  Turkce metin panoya girer, Ctrl+V ile yapistir"
Write-Host "  F9 ayni sey, Ingilizce icin"
Write-Host ""
Write-Host "  Ayarlar : $Dest\config.ini"
Write-Host "  Kaldirma: $Dest\uninstall.ps1"
Write-Host ""
Read-Host "  Kapatmak icin Enter"
