# Talkey

Push a key, talk, push it again. What you said lands on your clipboard as text,
ready to paste anywhere with `Ctrl+V`.

- **F8** — Turkish
- **F9** — English

Everything runs on your own machine. Your audio never leaves it, and you only
need the internet once, while the model downloads.

## Install

1. Extract the zip.
2. Open a PowerShell window in that folder (click the address bar, type
   `powershell`, press Enter) and run:
   ```
   powershell -ExecutionPolicy Bypass -File install.ps1
   ```
   Windows marks `.ps1` files downloaded from the internet, so right-click →
   "Run with PowerShell" is refused under the default policy. The command above
   gets past that. (Alternative: right-click the zip → Properties → tick
   **Unblock**, then extract and use "Run with PowerShell".)
3. The installer asks for a microphone and a model size. Pressing Enter twice
   takes the defaults.

It installs Python 3 and AutoHotkey v2 through `winget` if they are missing,
copies everything into `%LOCALAPPDATA%\Talkey`, builds an isolated Python
environment, and registers Talkey to start with Windows. No administrator
rights needed.

The first install downloads the speech model (~1.5 GB for `medium`), which
takes a few minutes. Later launches download nothing.

## Using it

| What | How |
|---|---|
| Dictate in Turkish | `F8` → speak → `F8` |
| Dictate in English | `F9` → speak → `F9` |
| Paste the text | `Ctrl+V` |
| Copy the last text again | Tray icon → "Copy last text" |
| Quit | Tray icon → "Exit" |

A small bubble in the corner tracks the state: `listening` → `transcribing...`
→ `Copied`.

Text goes **only to the clipboard**. Nothing is typed into a window on your
behalf, so there is no risk of it landing in the wrong place.

## Settings

`%LOCALAPPDATA%\Talkey\config.ini`

| Key | What it does |
|---|---|
| `[audio] device` | Microphone. Empty = the Windows default. Part of the device name is enough. |
| `[audio] max_seconds` | If you forget to stop, recording ends by itself after this long. |
| `[whisper] model` | `small`, `medium`, `large-v3`. Bigger is more accurate and slower. |
| `[whisper] compute` | `auto`, `cpu`, `cuda:float16`. The installer sets this for your machine. |
| `[lang] primary` / `secondary` | The two keys' languages (`tr`, `en`, `de`, `fr`, …). Whisper is multilingual, so any of its 99 languages works. |
| `[hotkeys] primary` / `secondary` | The hotkeys. `F8`, `F9`, `^!d` (Ctrl+Alt+D), and so on. |
| `[daemon] idle_unload` | The model is dropped from RAM after this many idle seconds. |

After editing:

- changed `[whisper]` or `[daemon]` → tray icon → **Restart daemon**
- changed `[hotkeys]`, `[lang]` or `[audio]` → tray icon → **Exit**, then start
  `Talkey` again from the Start menu (or reboot)

## How it works

```
F8  ──▶ dictate.ahk ──▶ dictate-record.py   (microphone → 16 kHz mono WAV)
                             │
F8  ──▶ dictate.ahk ─────────┘ stop
         │
         └─▶ dictate-client.py ──TCP 127.0.0.1──▶ dictate-daemon.py
                                                    (faster-whisper, model in RAM)
         ◀────────────── text ──────────────────────┘
         │
         └─▶ clipboard
```

The model stays loaded in a background daemon instead of being read from disk
for every dictation, which is why transcription takes seconds rather than half
a minute. After a long idle stretch it unloads itself and reloads on the next
use.

Recording stops by dropping a sentinel file rather than killing the recorder,
so the WAV header is always closed properly and you never get a truncated
recording.

Built on [faster-whisper](https://github.com/SYSTRAN/faster-whisper) with
OpenAI's Whisper models, [sounddevice](https://python-sounddevice.readthedocs.io)
for capture, and [AutoHotkey v2](https://www.autohotkey.com) for the hotkeys.

## Troubleshooting

**Nothing happens and there is no tray icon**
Press Win+R, type `shell:startup`, press Enter, and check that `Talkey.lnk` is
there. If it is not, run `install.ps1` again.

**"Microphone would not open"**
Check `%LOCALAPPDATA%\Talkey\record.log`. Usually it is the Windows privacy
setting: Settings → Privacy & security → Microphone → "Let desktop apps access
your microphone" must be on.

**It is listening to the wrong microphone**
Put part of the device name in `[audio] device` in `config.ini`. To see the
list of devices:
```
%LOCALAPPDATA%\Talkey\venv\Scripts\python.exe %LOCALAPPDATA%\Talkey\dictate-record.py --list
```

**"Could not start the daemon"**
Check `%LOCALAPPDATA%\Talkey\daemon.log`. If you see a `cudnn` or `cublas`
error, set `compute = cpu` in `config.ini` and restart the daemon.

**Transcription is slow**
Set `model = small` in `config.ini` and restart the daemon. Note that the first
dictation after a restart is always slow while the model loads; the rest are
fast.

**F8 is taken by another program**
Change `[hotkeys] primary` in `config.ini`, for example to `^!d` (Ctrl+Alt+D).
`^` is Ctrl, `!` is Alt, `+` is Shift, `#` is Win.

## Uninstall

Run `%LOCALAPPDATA%\Talkey\uninstall.ps1`. It asks separately before deleting
the install folder and the downloaded models, and leaves Python and AutoHotkey
alone.

## License

MIT
