#!/usr/bin/env python3
"""Warm whisper daemon: load the model once, keep it in RAM, transcribe on request.

Protocol:
  request  (client -> daemon): "<lang>\t<model>\t<wav_path>\n"
  response (daemon -> client): transcribed text (utf-8), then close.

The endpoint is an AF_UNIX socket on Linux and a loopback TCP port on Windows;
talkey_cfg hides the difference.

One model is held at a time. Asking for a different size evicts the previous
one, and the model is dropped entirely after [daemon] idle_unload seconds of
inactivity - medium/int8 is well over a gigabyte resident, which is a lot to
hold idle. The next request after an unload pays the reload.
"""
import gc
import os
import socket
import sys
import time
import traceback

from faster_whisper import WhisperModel

import talkey_cfg

_models = {}
_POLL_SEC = 30.0  # how often accept() wakes up to check the idle clock


def say(msg):
    talkey_cfg.log("daemon", f"{time.strftime('%Y-%m-%d %H:%M:%S')} {msg}")


def get_model(size, device, compute_type):
    if size not in _models:
        if _models:  # only ever hold one - large-v3 on top of medium is ~4 GB
            _models.clear()
            gc.collect()
        say(f"loading model {size} ({device}/{compute_type})")
        _models[size] = WhisperModel(size, device=device, compute_type=compute_type)
        say(f"model {size} ready")
    return _models[size]


def unload():
    if not _models:
        return
    sizes = ",".join(_models)
    _models.clear()
    gc.collect()
    talkey_cfg.trim_memory()
    say(f"unloaded idle model(s): {sizes}")


def main():
    cfg = talkey_cfg.load()
    idle_unload = cfg.getint("daemon", "idle_unload")
    default_model = cfg.get("whisper", "model")
    beam_size = cfg.getint("whisper", "beam_size")
    device, compute_type = talkey_cfg.resolve_compute(cfg.get("whisper", "compute"))

    try:
        srv, endpoint = talkey_cfg.server_socket(cfg)
    except OSError as exc:
        say(f"not starting, another daemon seems to be running ({exc})")
        return 0
    srv.listen(4)
    srv.settimeout(_POLL_SEC)

    get_model(default_model, device, compute_type)  # preload: first request is instant
    say(f"ready on {endpoint} (model={default_model}, idle-unload={idle_unload}s)")

    last_used = time.monotonic()
    while True:
        try:
            conn, _ = srv.accept()
        except socket.timeout:
            if _models and time.monotonic() - last_used > idle_unload:
                unload()
            continue

        try:
            data = b""
            while not data.endswith(b"\n"):
                chunk = conn.recv(4096)
                if not chunk:
                    break
                data += chunk
            lang, model, wav = data.decode("utf-8").strip().split("\t")
            whisper = get_model(model or default_model, device, compute_type)
            segments, _ = whisper.transcribe(
                wav,
                language=(lang or "tr"),
                vad_filter=True,
                beam_size=beam_size,
            )
            text = "".join(s.text for s in segments).strip()
            say(f"[{lang}] {os.path.basename(wav)} -> {len(text)} chars")
            conn.sendall(text.encode("utf-8"))
        except Exception:
            say("ERROR\n" + traceback.format_exc())
            try:
                conn.sendall(b"")
            except OSError:
                pass
        finally:
            conn.close()
            last_used = time.monotonic()


if __name__ == "__main__":
    sys.exit(main())
