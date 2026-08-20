#!/usr/bin/env bash
# Talkey installer for Linux.
#
#   ./install.sh [--prefix DIR] [--no-service] [--no-hotkeys] [--model NAME]
#
# Installs into ~/.local/share/talkey by default, creates an isolated venv,
# downloads the whisper model, registers a systemd user service and (on GNOME)
# the two hotkeys. No root required.
set -euo pipefail

PREFIX="$HOME/.local/share/talkey"
WITH_SERVICE=1
WITH_HOTKEYS=1
MODEL=""
SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$SRC")"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --no-service) WITH_SERVICE=0; shift ;;
        --no-hotkeys) WITH_HOTKEYS=0; shift ;;
        --model) MODEL="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
info() { printf '    \033[90m%s\033[0m\n' "$1"; }
warn() { printf '    \033[33m%s\033[0m\n' "$1"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$1" >&2; exit 1; }

printf '\n  Talkey - push-to-talk dictation\n'
info "Install prefix: $PREFIX"

# ------------------------------------------------------------------ 1. deps
step "Checking prerequisites"
command -v python3 >/dev/null || die "python3 not found."
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' \
    || die "Python 3.9 or newer is required (found $(python3 -V 2>&1))."
python3 -c 'import venv' 2>/dev/null || die "The venv module is missing. Install python3-venv (Debian/Ubuntu) or python3-libs (Fedora)."
info "python3: $(command -v python3) ($(python3 -V 2>&1 | cut -d' ' -f2))"

missing=()
command -v notify-send >/dev/null || missing+=("libnotify-bin / libnotify")
if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    command -v wl-copy >/dev/null || missing+=("wl-clipboard")
else
    command -v xclip >/dev/null || command -v xsel >/dev/null || missing+=("xclip")
fi
if (( ${#missing[@]} )); then
    warn "Missing optional tools: ${missing[*]}"
    warn "Install them with your package manager, for example:"
    if command -v apt >/dev/null; then
        warn "  sudo apt install wl-clipboard libnotify-bin"
    elif command -v dnf >/dev/null; then
        warn "  sudo dnf install wl-clipboard libnotify"
    elif command -v pacman >/dev/null; then
        warn "  sudo pacman -S wl-clipboard libnotify"
    fi
    warn "Talkey still installs, but it cannot copy or notify without them."
fi

# ------------------------------------------------------------------ 2. files
step "Copying files"
mkdir -p "$PREFIX"
for f in talkey_cfg.py talkey-daemon.py talkey-client.py talkey-record.py; do
    [[ -f "$REPO/shared/$f" ]] || die "missing file in the package: shared/$f"
    install -m 644 "$REPO/shared/$f" "$PREFIX/$f"
done
install -m 755 "$SRC/talkey" "$PREFIX/talkey"
install -m 755 "$SRC/uninstall.sh" "$PREFIX/uninstall.sh"
[[ -f "$REPO/README.md" ]] && install -m 644 "$REPO/README.md" "$PREFIX/README.md"
info "-> $PREFIX"

# ------------------------------------------------------------------ 3. venv
step "Preparing the Python environment (this can take a few minutes)"
VENV="$PREFIX/venv"
[[ -x "$VENV/bin/python" ]] || python3 -m venv "$VENV"
"$VENV/bin/python" -m pip install --upgrade pip --quiet
"$VENV/bin/python" -m pip install --upgrade faster-whisper sounddevice \
    || die "Could not install faster-whisper / sounddevice."
info "faster-whisper + sounddevice ready"

# ------------------------------------------------------------------ 4. config
step "Writing config.ini"
if [[ -f "$PREFIX/config.ini" ]]; then
    info "config.ini already exists, keeping it"
else
    if [[ -z "$MODEL" ]]; then
        printf '     1) small     - fastest, moderate accuracy    (~0.5 GB)\n'
        printf '     2) medium    - recommended balance           (~1.5 GB)\n'
        printf '     3) large-v3  - most accurate, slow on CPU    (~3 GB)\n'
        read -rp "    Choice (Enter = 2): " pick || pick=""
        case "${pick:-2}" in
            1) MODEL=small ;;
            3) MODEL=large-v3 ;;
            *) MODEL=medium ;;
        esac
    fi
    COMPUTE=cpu
    if "$VENV/bin/python" -c 'import ctranslate2, sys; sys.exit(0 if ctranslate2.get_cuda_device_count() else 1)' 2>/dev/null; then
        info "A CUDA device is visible, loading a tiny model to see whether it really works..."
        # get_cuda_device_count() only sees the driver. Without cuBLAS/cuDNN the
        # model load blows up, so test it rather than assuming the GPU is usable.
        if "$VENV/bin/python" -c "from faster_whisper import WhisperModel; WhisperModel('tiny', device='cuda', compute_type='float16')" >/dev/null 2>&1; then
            COMPUTE=cuda:float16
            info "Using the GPU (cuda/float16)"
        else
            warn "A GPU is present but cuBLAS/cuDNN look missing, falling back to CPU."
        fi
    else
        info "No GPU, using the CPU (cpu/int8)"
    fi
    cat > "$PREFIX/config.ini" <<EOF
; Talkey settings. After editing:
;   - changed [whisper] or [daemon]: systemctl --user restart talkey-daemon
;   - changed [lang] or [audio]: nothing, the next dictation picks it up
;   - changed [hotkeys]: rebind the keys in your desktop's keyboard settings

[audio]
; Empty = your system default input, which follows whatever you pick in your
; desktop's sound settings. Part of a device name also works; run
;   $VENV/bin/python $PREFIX/talkey-record.py --list
; to see what is available.
device =
; If you forget to press the key again, recording stops by itself after this many seconds.
max_seconds = 600

[whisper]
model = $MODEL
; auto | cpu | cuda | cuda:float16 | cpu:int8
compute = $COMPUTE
beam_size = 5

[lang]
primary = tr
secondary = en

[hotkeys]
primary = F8
secondary = F9

[daemon]
; The model is dropped from RAM after this many idle seconds.
idle_unload = 600
startup_timeout = 300
EOF
    info "$PREFIX/config.ini"
fi

# ------------------------------------------------------------------ 5. model
step "Downloading and testing the model (long the first time)"
( cd "$PREFIX" && "$VENV/bin/python" -c "
import talkey_cfg
from faster_whisper import WhisperModel
cfg = talkey_cfg.load()
d, c = talkey_cfg.resolve_compute(cfg.get('whisper', 'compute'))
WhisperModel(cfg.get('whisper', 'model'), device=d, compute_type=c)
print('model ok')
" ) || die "The model could not be loaded. Check your internet connection and try again."

# ------------------------------------------------------------------ 6. service
if (( WITH_SERVICE )); then
    step "Installing the systemd user service"
    UNIT_DIR="$HOME/.config/systemd/user"
    mkdir -p "$UNIT_DIR"
    cat > "$UNIT_DIR/talkey-daemon.service" <<EOF
[Unit]
Description=Talkey warm whisper daemon (model kept in RAM)

[Service]
Type=simple
ExecStart=$VENV/bin/python $PREFIX/talkey-daemon.py
WorkingDirectory=$PREFIX
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable --now talkey-daemon.service
    info "talkey-daemon.service enabled and started"
else
    info "Skipping the systemd service (--no-service)"
fi

# ------------------------------------------------------------------ 7. hotkeys
if (( WITH_HOTKEYS )); then
    step "Registering hotkeys"
    if command -v gsettings >/dev/null && gsettings list-schemas 2>/dev/null | grep -q '^org.gnome.settings-daemon.plugins.media-keys$'; then
        PREFIX="$PREFIX" python3 - <<'PYEOF'
import configparser, os, subprocess

prefix = os.environ["PREFIX"]
cfg = configparser.ConfigParser()
cfg.read(os.path.join(prefix, "config.ini"), encoding="utf-8")
primary = cfg.get("hotkeys", "primary", fallback="F8")
secondary = cfg.get("hotkeys", "secondary", fallback="F9")
lang_primary = cfg.get("lang", "primary", fallback="tr")
lang_secondary = cfg.get("lang", "secondary", fallback="en")

SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
ROOT = "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"


def gs(*args):
    return subprocess.run(["gsettings", *args], capture_output=True, text=True).stdout.strip()


existing = gs("get", SCHEMA, "custom-keybindings")
paths = [p.strip().strip("'") for p in existing.strip("[]").split(",") if p.strip() not in ("", "@as")]

# Warn instead of silently creating a second binding for a key that is taken.
for path in list(paths):
    if "/talkey" in path:
        continue
    key = gs("get", f"{SCHEMA}.custom-keybinding:{path}", "binding").strip("'")
    name = gs("get", f"{SCHEMA}.custom-keybinding:{path}", "name").strip("'")
    if key in (primary, secondary):
        print(f"    \033[33m{key} is already bound to \"{name}\". "
              f"Talkey will also claim it; unbind the other one if it misbehaves.\033[0m")

for slug, key, lang in (("talkey", primary, lang_primary), ("talkey-en", secondary, lang_secondary)):
    path = f"{ROOT}/{slug}/"
    if path not in paths:
        paths.append(path)
    target = f"{SCHEMA}.custom-keybinding:{path}"
    subprocess.run(["gsettings", "set", target, "name", f"Talkey ({lang})"], check=True)
    subprocess.run(["gsettings", "set", target, "command", f"{prefix}/talkey {lang}"], check=True)
    subprocess.run(["gsettings", "set", target, "binding", key], check=True)
    print(f"    {key} -> talkey {lang}")

value = "[" + ", ".join(f"'{p}'" for p in paths) + "]"
subprocess.run(["gsettings", "set", SCHEMA, "custom-keybindings", value], check=True)
PYEOF
    else
        warn "Not GNOME, so the hotkeys were not registered automatically."
        warn "Bind these two commands to keys in your desktop's keyboard settings:"
        warn "  $PREFIX/talkey tr"
        warn "  $PREFIX/talkey en"
    fi
else
    info "Skipping hotkey registration (--no-hotkeys)"
fi

printf '\n\033[32m  All set.\033[0m\n\n'
printf '  Press F8, speak, press F8 again. The text lands on your clipboard.\n'
printf '  F9 does the same in English.\n\n'
printf '  Settings  : %s/config.ini\n' "$PREFIX"
printf '  Uninstall : %s/uninstall.sh\n\n' "$PREFIX"
