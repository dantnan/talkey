#!/usr/bin/env python3
"""Sentinel-driven recorder: 16 kHz mono s16 WAV until a stop file appears.

    talkey-record.py --list
    talkey-record.py <wav> <stopfile> <readyfile>

Stopping by sentinel file rather than by killing the process is deliberate: the
WAV header stores the data length, and a hard kill leaves it unpatched, so the
file decodes as empty or truncated. Here the `wave` module always closes the
file properly.

`<readyfile>` is touched the moment the input stream is actually open, so the
hotkey script only says "listening" once the microphone really is live.
"""
import os
import queue
import sys
import time
import wave

import talkey_cfg

# PortAudio is loaded at import time and throws when the machine has no usable
# audio stack at all. This process runs windowless, so an uncaught import error
# would vanish with no log and the hotkey would only say the microphone would
# not open. Catch it here and leave a readable reason behind instead.
try:
    import sounddevice as sd
except Exception as _exc:  # noqa: BLE001 - any import failure must be reported
    talkey_cfg.log(
        "record",
        f"FATAL could not load the audio library: {type(_exc).__name__}: {_exc}\n"
        "The system reports no usable audio input stack. Check that a microphone "
        "is connected and enabled in Sound settings.",
    )
    sys.exit(1)

RATE = 16000
CHANNELS = 1
BLOCK = 1600  # 100 ms


def list_devices():
    for index, dev in enumerate(sd.query_devices()):
        if dev["max_input_channels"] > 0:
            print(f"{index}\t{dev['name']}")


def resolve_device(setting):
    """Config value -> sounddevice device id. Empty means the system default."""
    setting = (setting or "").strip()
    if not setting:
        return None
    if setting.isdigit():
        return int(setting)
    wanted = setting.casefold()
    for index, dev in enumerate(sd.query_devices()):
        if dev["max_input_channels"] > 0 and wanted in dev["name"].casefold():
            return index
    talkey_cfg.log("record", f"device not found, using default: {setting}")
    return None


def record(wav_path, stop_path, ready_path):
    cfg = talkey_cfg.load()
    device = resolve_device(cfg.get("audio", "device"))
    max_seconds = cfg.getint("audio", "max_seconds")

    for stale in (stop_path, ready_path, wav_path):
        try:
            os.remove(stale)
        except OSError:
            pass

    chunks = queue.Queue()

    def callback(indata, frames, time_info, status):
        if status:
            talkey_cfg.log("record", f"stream status: {status}")
        chunks.put(bytes(indata))

    stream = sd.RawInputStream(
        samplerate=RATE,
        channels=CHANNELS,
        dtype="int16",
        blocksize=BLOCK,
        device=device,
        callback=callback,
    )
    with stream, wave.open(wav_path, "wb") as wav:
        wav.setnchannels(CHANNELS)
        wav.setsampwidth(2)
        wav.setframerate(RATE)
        open(ready_path, "wb").close()

        started = time.monotonic()
        while not os.path.exists(stop_path):
            if time.monotonic() - started > max_seconds:
                talkey_cfg.log("record", f"hit max_seconds ({max_seconds}), stopping")
                break
            try:
                wav.writeframes(chunks.get(timeout=0.1))
            except queue.Empty:
                pass
        while True:  # drain whatever the callback queued during shutdown
            try:
                wav.writeframes(chunks.get_nowait())
            except queue.Empty:
                break


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        list_devices()
        return 0
    if len(sys.argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        record(sys.argv[1], sys.argv[2], sys.argv[3])
    except Exception as exc:
        talkey_cfg.log("record", f"ERROR {type(exc).__name__}: {exc}")
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        # Windowless again: the log is the only place this can surface.
        import traceback

        talkey_cfg.log("record", "ERROR\n" + traceback.format_exc())
        sys.exit(1)
