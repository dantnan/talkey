#Requires -Version 5.1
<#
    Talkey installer.

    Usage:  powershell -ExecutionPolicy Bypass -File install.ps1

    What it does:
      1. Installs Python 3 and AutoHotkey v2 through winget if they are missing
      2. Copies the files into %LOCALAPPDATA%\Talkey
      3. Creates an isolated venv with faster-whisper + sounddevice
      4. Asks for your microphone and model size, writes config.ini
      5. Downloads the whisper model (~1.5 GB the first time)
      6. Adds startup shortcuts and launches everything

    No administrator rights required.
#>
$ErrorActionPreference = 'Stop'

[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
$env:PYTHONIOENCODING = 'utf-8'

$Src = $PSScriptRoot
if (-not $Src) { $Src = Split-Path -Parent $MyInvocation.MyCommand.Path }
$Dest = Join-Path $env:LOCALAPPDATA 'Talkey'
$Repo = Split-Path -Parent $Src
# Cross-platform pieces live in shared/, the Windows-only ones next to this script.
$SharedFiles = @('talkey_cfg.py', 'talkey-daemon.py', 'talkey-client.py', 'talkey-record.py')
$WindowsFiles = @('talkey.ahk', 'restart-daemon.ps1', 'uninstall.ps1')

function Step($msg) { Write-Host ""; Write-Host "==> $msg" -ForegroundColor Cyan }
function Info($msg) { Write-Host "    $msg" -ForegroundColor DarkGray }
function Warn($msg) { Write-Host "    $msg" -ForegroundColor Yellow }
function Die($msg) { Write-Host ""; Write-Host "ERROR: $msg" -ForegroundColor Red; Read-Host "  Press Enter to close"; exit 1 }

# pip and winget write to stderr even on success, which aborts the script under
# $ErrorActionPreference = 'Stop' on PowerShell 5.1. Route every external command
# through here and judge success by $LASTEXITCODE instead.
function Invoke-Native {
    $exe = $args[0]
    $rest = @()
    if ($args.Count -gt 1) { $rest = $args[1..($args.Count - 1)] }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $exe @rest
    } catch {
        # Missing or unrunnable program. Throwing here would kill the install, and
        # every caller already checks the exit code.
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
    # The Microsoft Store "python.exe" stub exits non-zero here, which is what
    # separates a real interpreter from the alias.
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
    # Right after a winget install the PATH in this session may still be stale.
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
        Die "$label is missing and winget was not found. Install 'App Installer' from the Microsoft Store, then run this script again."
    }
    Info "Installing $label (winget: $id)..."
    Invoke-Native 'winget' 'install' '-e' '--id' $id '--accept-package-agreements' '--accept-source-agreements' '--scope' 'user'
    if ($LASTEXITCODE -ne 0) {
        Info "User-scope install failed, trying machine scope..."
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

# ------------------------------------------------------------------ 0. preflight
Write-Host ""
Write-Host "  Talkey - push-to-talk dictation (F8 / F9)" -ForegroundColor White
Write-Host "  Install folder: $Dest" -ForegroundColor DarkGray

Get-ChildItem $Src -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
Get-ChildItem (Join-Path $Repo 'shared') -File -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue

foreach ($f in $SharedFiles) {
    if (-not (Test-Path (Join-Path $Repo "shared\$f"))) { Die "Missing file in the package: shared\$f" }
}
foreach ($f in $WindowsFiles) {
    if (-not (Test-Path (Join-Path $Src $f))) { Die "Missing file in the package: $f" }
}

# ------------------------------------------------------------------ 1. dependencies
Step "Looking for Python"
$python = Get-PythonExe
if (-not $python) {
    Install-WithWinget 'Python.Python.3.12' 'Python 3.12'
    $python = Get-PythonExe
    if (-not $python) { Die "Python was installed but could not be found. Reboot and run this script again." }
}
Info "Python: $python"

Step "Looking for AutoHotkey v2"
$ahk = Get-AhkExe
if (-not $ahk) {
    Install-WithWinget 'AutoHotkey.AutoHotkey' 'AutoHotkey v2'
    $ahk = Get-AhkExe
    if (-not $ahk) { Die "AutoHotkey was installed but AutoHotkey64.exe could not be found." }
}
Info "AutoHotkey: $ahk"

# ------------------------------------------------------------------ 2. files
Step "Copying files"
New-Item -ItemType Directory -Force -Path $Dest | Out-Null
foreach ($f in $SharedFiles) { Copy-Item (Join-Path $Repo "shared\$f") $Dest -Force }
foreach ($f in $WindowsFiles) { Copy-Item (Join-Path $Src $f) $Dest -Force }
$readme = Join-Path $Repo 'README.md'
if (Test-Path $readme) { Copy-Item $readme $Dest -Force }

# v1.0.0 shipped these under their old names; drop them so an upgraded install
# does not keep dead copies alongside the current ones.
foreach ($old in @('dictate.ahk', 'dictate-daemon.py', 'dictate-client.py', 'dictate-record.py', 'dikte_cfg.py')) {
    $p = Join-Path $Dest $old
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}
Info "$($SharedFiles.Count + $WindowsFiles.Count) files -> $Dest"

# ------------------------------------------------------------------ 3. venv
$venv = Join-Path $Dest 'venv'
$venvPy = Join-Path $venv 'Scripts\python.exe'
$venvPyw = Join-Path $venv 'Scripts\pythonw.exe'

Step "Preparing the Python environment (this can take a few minutes)"
if (-not (Test-Path $venvPy)) {
    Invoke-Native $python '-m' 'venv' $venv
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $venvPy)) { Die "Could not create the venv." }
}
Invoke-Native $venvPy '-m' 'pip' 'install' '--upgrade' 'pip' '--quiet'
Invoke-Native $venvPy '-m' 'pip' 'install' '--upgrade' 'faster-whisper' 'sounddevice'
if ($LASTEXITCODE -ne 0) { Die "Could not install faster-whisper / sounddevice. Check your internet connection." }
Info "faster-whisper + sounddevice ready"

$cfgPath = Join-Path $Dest 'config.ini'
if (Test-Path $cfgPath) {
    Step "Settings"
    Info "config.ini already exists, keeping it"
} else {
# ------------------------------------------------------------------ 4. microphone
Step "Microphone"
$raw = Invoke-Native $venvPy (Join-Path $Dest 'talkey-record.py') '--list'
$mics = @()
foreach ($line in $raw) {
    $parts = "$line".Split("`t")
    if ($parts.Count -ge 2) { $mics += [pscustomobject]@{ Index = $parts[0]; Name = $parts[1] } }
}
if ($mics.Count -eq 0) {
    Warn "No input devices listed, the Windows default microphone will be used."
    $micValue = ''
} else {
    Write-Host "     0) Windows default microphone (recommended)"
    for ($i = 0; $i -lt $mics.Count; $i++) {
        Write-Host ("    {0,2}) {1}" -f ($i + 1), $mics[$i].Name)
    }
    $pick = Read-Host "    Choice (Enter = 0)"
    if ([string]::IsNullOrWhiteSpace($pick) -or "$pick".Trim() -eq '0') {
        $micValue = ''
    } else {
        $n = 0
        if ([int]::TryParse("$pick".Trim(), [ref]$n) -and $n -ge 1 -and $n -le $mics.Count) {
            $micValue = $mics[$n - 1].Name
        } else {
            Warn "Not a valid choice, using the default microphone."
            $micValue = ''
        }
    }
}

# ------------------------------------------------------------------ 5. model
Step "Model"
Write-Host "     1) small     - fastest, moderate accuracy    (~0.5 GB)"
Write-Host "     2) medium    - recommended balance           (~1.5 GB)"
Write-Host "     3) large-v3  - most accurate, slow on CPU    (~3 GB)"
$pick = Read-Host "    Choice (Enter = 2)"
switch ("$pick".Trim()) {
    '1' { $model = 'small' }
    '3' { $model = 'large-v3' }
    default { $model = 'medium' }
}
Info "Model: $model"

Step "Checking for a GPU"
$compute = 'cpu'
$gpuCount = Invoke-Native $venvPy '-c' 'import ctranslate2; print(ctranslate2.get_cuda_device_count())' 2>$null
if ($LASTEXITCODE -eq 0 -and "$gpuCount".Trim() -ne '' -and "$gpuCount".Trim() -ne '0') {
    Info "A CUDA device is visible, loading a tiny model to see whether it really works..."
    # get_cuda_device_count() only sees the driver. Without cuBLAS/cuDNN the model
    # load blows up, so test it here rather than assuming the GPU is usable.
    Invoke-Native $venvPy '-c' "from faster_whisper import WhisperModel; WhisperModel('tiny', device='cuda', compute_type='float16')" 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $compute = 'cuda:float16'
        Info "Using the GPU (cuda/float16)"
    } else {
        Warn "A GPU is present but cuBLAS/cuDNN look missing, falling back to CPU."
    }
} else {
    Info "No GPU, using the CPU (cpu/int8)"
}

# ------------------------------------------------------------------ 6. config
Step "Writing config.ini"
$cfg = @"
; Talkey settings. After editing:
;   - changed [whisper] or [daemon]: tray menu > "Restart daemon"
;   - changed [hotkeys], [lang] or [audio]: tray menu > Exit, then start Talkey again

[audio]
; Empty = the Windows default microphone. Part of the device name is enough.
device = $micValue
; If you forget to press the key again, recording stops by itself after this many seconds.
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
; The model is dropped from RAM after this many idle seconds.
idle_unload = 600
startup_timeout = 300
"@
[IO.File]::WriteAllText($cfgPath, $cfg, (New-Object System.Text.UTF8Encoding($false)))
Info $cfgPath
}

# ------------------------------------------------------------------ 7. model download
Step "Downloading and testing the model (long the first time)"
Push-Location $Dest
Invoke-Native $venvPy '-c' "import talkey_cfg; from faster_whisper import WhisperModel; cfg = talkey_cfg.load(); d, c = talkey_cfg.resolve_compute(cfg.get('whisper', 'compute')); WhisperModel(cfg.get('whisper', 'model'), device=d, compute_type=c); print('model ok')"
$modelOk = ($LASTEXITCODE -eq 0)
Pop-Location
if (-not $modelOk) { Die "The model could not be loaded. Check your internet connection and try again." }

# ------------------------------------------------------------------ 8. startup
Step "Adding startup shortcuts"
$startup = [Environment]::GetFolderPath('Startup')
New-Shortcut (Join-Path $startup 'Talkey.lnk') $ahk ('"{0}"' -f (Join-Path $Dest 'talkey.ahk')) $Dest
New-Shortcut (Join-Path $startup 'Talkey Daemon.lnk') $venvPyw ('"{0}"' -f (Join-Path $Dest 'talkey-daemon.py')) $Dest
Info "$startup\Talkey.lnk"
Info "$startup\Talkey Daemon.lnk"

# ------------------------------------------------------------------ 9. launch
Step "Starting"
Invoke-Native 'powershell' '-NoProfile' '-ExecutionPolicy' 'Bypass' '-File' (Join-Path $Dest 'restart-daemon.ps1')
Start-Process -FilePath $ahk -ArgumentList ('"{0}"' -f (Join-Path $Dest 'talkey.ahk')) -WorkingDirectory $Dest

Write-Host ""
Write-Host "  All set." -ForegroundColor Green
Write-Host ""
Write-Host "  Press F8, speak, press F8 again. The text lands on your clipboard, paste with Ctrl+V."
Write-Host "  F9 does the same in English."
Write-Host ""
Write-Host "  Settings  : $Dest\config.ini"
Write-Host "  Uninstall : $Dest\uninstall.ps1"
Write-Host ""
Read-Host "  Press Enter to close"
