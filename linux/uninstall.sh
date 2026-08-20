#!/usr/bin/env bash
# Talkey uninstaller for Linux.
#
#   ./uninstall.sh [--prefix DIR]
set -uo pipefail

PREFIX="$HOME/.local/share/talkey"
[[ "${1:-}" == "--prefix" ]] && PREFIX="$2"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
info() { printf '    \033[90m%s\033[0m\n' "$1"; }

step "Stopping the service"
systemctl --user disable --now talkey-daemon.service 2>/dev/null && info "talkey-daemon.service stopped"
rm -f "$HOME/.config/systemd/user/talkey-daemon.service"
systemctl --user daemon-reload 2>/dev/null

step "Removing hotkeys"
if command -v gsettings >/dev/null; then
    python3 - <<'PYEOF'
import subprocess

SCHEMA = "org.gnome.settings-daemon.plugins.media-keys"
current = subprocess.run(["gsettings", "get", SCHEMA, "custom-keybindings"],
                         capture_output=True, text=True).stdout.strip()
paths = [p.strip().strip("'") for p in current.strip("[]").split(",")
         if p.strip() not in ("", "@as")]
keep = [p for p in paths if "/talkey" not in p]
for path in paths:
    if path in keep:
        continue
    target = f"{SCHEMA}.custom-keybinding:{path}"
    for key in ("name", "command", "binding"):
        subprocess.run(["gsettings", "reset", target, key], capture_output=True)
    print(f"    removed: {path}")
value = "@as []" if not keep else "[" + ", ".join(f"'{p}'" for p in keep) + "]"
subprocess.run(["gsettings", "set", SCHEMA, "custom-keybindings", value], check=False)
PYEOF
fi

step "Clearing temporary files"
rm -rf "${XDG_RUNTIME_DIR:-/tmp}/talkey"

read -rp "    Delete the install folder too? ($PREFIX) [y/N] " answer
if [[ "${answer:-}" =~ ^[yY] ]]; then
    rm -rf "$PREFIX"
    info "removed: $PREFIX"
fi

read -rp "    Delete the downloaded whisper models too? (~1.5 GB) [y/N] " answer
if [[ "${answer:-}" =~ ^[yY] ]]; then
    for d in "$HOME/.cache/huggingface/hub/"*faster-whisper*; do
        [[ -e "$d" ]] || continue
        rm -rf "$d"
        info "removed: $(basename "$d")"
    done
fi

printf '\n\033[32m  Done. Python was left installed.\033[0m\n\n'
