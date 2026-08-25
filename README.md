# Talkey

Push a key, talk, push it again. What you said lands on your clipboard as text,
ready to paste anywhere.

- **F8** — Turkish
- **F9** — English

Both keys and both languages are configurable, and Whisper is multilingual, so
any of its 99 languages works.

Everything runs on your own machine. Your audio never leaves it, there is no
account and no API key, and you only need the internet once, while the model
downloads.

Works on **Windows** and **Linux**.

## Install

### Windows

1. Download `talkey.zip` from the
   [latest release](https://github.com/dantnan/talkey/releases/latest) and
   extract it.
2. Open a PowerShell window in the `windows` folder (click the address bar,
   type `powershell`, press Enter) and run:
   ```
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```
   Windows marks `.ps1` files downloaded from the internet, so right-click →
   "Run with PowerShell" is refused under the default policy. The command above
   gets past that. (Alternative: right-click the zip → Properties → tick
   **Unblock**, then extract.)
3. The installer asks for a microphone and a model size. Pressing Enter twice
   takes the defaults.

It installs Python 3 and AutoHotkey v2 through `winget` if they are missing,
copies everything into `%LOCALAPPDATA%\Talkey`, builds an isolated Python
environment, and registers Talkey to start with Windows. No administrator
rights needed.

### Linux

```
git clone https://github.com/dantnan/talkey
cd talkey/linux
./install.sh
```

It installs into `~/.local/share/talkey`, builds an isolated venv, registers a
systemd user service, and on GNOME binds the two hotkeys for you. No root
needed.

You need `python3` with the `venv` module, plus `wl-clipboard` (Wayland) or
`xclip` (X11) and `libnotify`. The installer tells you the exact command if
anything is missing.

On desktops other than GNOME the installer prints the two commands to bind
yourself in your keyboard settings:

```
~/.local/share/talkey/talkey tr
~/.local/share/talkey/talkey en
```

Options: `--prefix DIR`, `--model NAME`, `--no-service`, `--no-hotkeys`.

### Both

The first install downloads the speech model (~1.5 GB for `medium`), which
takes a few minutes. Later launches download nothing. Reinstalling keeps your
existing `config.ini`.

## Using it

| What | How |
|---|---|
| Dictate in Turkish | `F8` → speak → `F8` |
| Dictate in English | `F9` → speak → `F9` |
| Paste the text | `Ctrl+V` |

A small notification tracks the state: `listening` → `transcribing...` →
`Copied`. On Windows there is also a tray icon with "Copy last text", "Restart
daemon" and "Open install folder".

Text goes **only to the clipboard**. Nothing is typed into a window on your
behalf, so it can never land in the wrong place. This also sidesteps the fact
that synthetic keystrokes are unreliable or unavailable under Wayland.

## Settings

- Windows: `%LOCALAPPDATA%\Talkey\config.ini`
- Linux: `~/.local/share/talkey/config.ini`

| Key | What it does |
|---|---|
| `[audio] device` | Microphone. Empty = your system default. Part of the device name also works. |
| `[audio] max_seconds` | If you forget to stop, recording ends by itself after this long. |
| `[audio] mute_output` | `1` silences the speakers while recording so playing audio does not bleed into the mic. The previous mute state is restored afterwards. `0` turns it off. |
| `[audio] done_sound` | `1` plays a short chime when the text hits the clipboard, so you do not have to look at the screen. `0` turns it off. |
| `[whisper] model` | `small`, `medium`, `large-v3`. Bigger is more accurate and slower. |
| `[whisper] compute` | `auto`, `cpu`, `cuda:float16`. The installer sets this for your machine. |
| `[lang] primary` / `secondary` | The two keys' languages (`tr`, `en`, `de`, `fr`, …). |
| `[hotkeys] primary` / `secondary` | The hotkeys. `F8`, `F9`, `^!d` (Ctrl+Alt+D on Windows), and so on. |
| `[daemon] idle_unload` | The model is dropped from RAM after this many idle seconds. |

After editing:

| Changed | Windows | Linux |
|---|---|---|
| `[whisper]`, `[daemon]` | tray → **Restart daemon** | `systemctl --user restart talkey-daemon` |
| `[lang]`, `[audio]` | tray → **Exit**, start Talkey again | nothing, next dictation picks it up |
| `[hotkeys]` | tray → **Exit**, start Talkey again | rebind in your keyboard settings |

To list input devices:

```
# Windows
%LOCALAPPDATA%\Talkey\venv\Scripts\python.exe %LOCALAPPDATA%\Talkey\talkey-record.py --list
# Linux
~/.local/share/talkey/venv/bin/python ~/.local/share/talkey/talkey-record.py --list
```

## How it works

```
key ──▶ hotkey layer ──▶ talkey-record.py   (microphone → 16 kHz mono WAV)
                              │
key ──▶ hotkey layer ─────────┘ stop
         │
         └─▶ talkey-client.py ──socket──▶ talkey-daemon.py
                                            (faster-whisper, model in RAM)
         ◀────────────── text ──────────────┘
         │
         └─▶ clipboard
```

The recorder, client and daemon are shared between platforms and live in
`shared/`. Only three things differ:

| | Windows | Linux |
|---|---|---|
| Hotkeys and clipboard | AutoHotkey v2 (`windows/talkey.ahk`) | a bash script (`linux/talkey`) with `wl-copy`/`xclip` |
| IPC | loopback TCP port | AF_UNIX socket, mode 0600 |
| Autostart | Startup folder shortcuts | systemd user service |

The model stays loaded in a background daemon instead of being read from disk
for every dictation, which is why transcription takes seconds rather than half
a minute. After a long idle stretch it unloads itself, handing the pages back
to the OS, and reloads on the next use. If the daemon is not running at all,
the client starts it on demand, so dictation still works even with the service
or logon entry removed.

Recording stops by dropping a sentinel file rather than killing the recorder,
so the WAV header is always closed properly and you never get a truncated
recording.

Built on [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with
OpenAI's Whisper models, [sounddevice](https://python-sounddevice.readthedocs.io)
for capture, and [AutoHotkey v2](https://www.autohotkey.com) for the Windows
hotkeys.

## Troubleshooting

Logs live in the install folder: `daemon.log`, `client.log`, `record.log`.

**Nothing happens when I press the key**
Windows: press Win+R, type `shell:startup`, and check that `Talkey.lnk` is
there. Linux: `systemctl --user status talkey-daemon` and check your keyboard
settings for the binding.

**"Microphone would not open"**
Check `record.log`. On Windows it is usually the privacy setting: Settings →
Privacy & security → Microphone → "Let desktop apps access your microphone".

**"Could not start the daemon"**
Check `daemon.log`. A `cudnn` or `cublas` error means the GPU is not usable;
set `compute = cpu` and restart the daemon.

**Transcription is slow**
Set `model = small` and restart the daemon. The first dictation after a restart
is always slow while the model loads; the rest are fast.

**The hotkey is taken by another program**
Change `[hotkeys]` in `config.ini` (Windows), or rebind in your desktop's
keyboard settings (Linux). On GNOME the installer warns you when a key is
already bound to something else.

**Linux: nothing is copied**
Install `wl-clipboard` on Wayland or `xclip` on X11.

## Uninstall

- Windows: `%LOCALAPPDATA%\Talkey\uninstall.ps1`
- Linux: `~/.local/share/talkey/uninstall.sh`

Both ask separately before deleting the install folder and the downloaded
models, and leave Python (and AutoHotkey) alone.

## macOS

Not planned. macOS already ships on-device dictation, the third-party market
there is crowded, and the problem that motivated Talkey (synthetic keystrokes
being broken under Wayland) does not exist on a Mac. If you want something like
this there, [Handy](https://github.com/cjpais/Handy) does it well.

## License

MIT
