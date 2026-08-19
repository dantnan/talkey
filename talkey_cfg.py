#!/usr/bin/env python3
"""Shared config/paths/logging for the Talkey scripts.

Every script lives next to config.ini, so the install directory is simply the
directory this module was imported from. Nothing here imports a third-party
package: the client must stay fast to start.
"""
import configparser
import os

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, "config.ini")

DEFAULTS = {
    "audio": {"device": "", "max_seconds": "600"},
    "whisper": {"model": "medium", "compute": "auto", "beam_size": "5"},
    "lang": {"primary": "tr", "secondary": "en"},
    "daemon": {
        "host": "127.0.0.1",
        "port": "47353",
        "idle_unload": "600",
        "startup_timeout": "300",
    },
    "hotkeys": {"primary": "F8", "secondary": "F9"},
}


def load():
    cp = configparser.ConfigParser()
    cp.read_dict(DEFAULTS)
    if os.path.exists(CFG_PATH):
        cp.read(CFG_PATH, encoding="utf-8")
    return cp


def workdir():
    """Scratch space for the wav and the sentinel files."""
    d = os.path.join(os.environ.get("TEMP") or BASE, "talkey")
    os.makedirs(d, exist_ok=True)
    return d


def log(name, msg):
    """Append a line to <install dir>\\<name>.log, truncating past 1 MB."""
    path = os.path.join(BASE, name + ".log")
    try:
        if os.path.exists(path) and os.path.getsize(path) > 1_000_000:
            os.remove(path)
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(msg.rstrip() + "\n")
    except OSError:
        pass


def resolve_compute(setting):
    """'auto' | 'cpu' | 'cuda' | 'cuda:float16' -> (device, compute_type).

    auto picks CUDA/float16 when CTranslate2 sees a GPU, else CPU/int8.
    """
    setting = (setting or "auto").strip().lower()
    if setting and setting != "auto":
        device, _, ctype = setting.partition(":")
        if not ctype:
            ctype = "float16" if device == "cuda" else "int8"
        return device, ctype
    try:
        import ctranslate2

        if ctranslate2.get_cuda_device_count() > 0:
            return "cuda", "float16"
    except Exception:  # no CUDA build, no driver, import failure - all mean CPU
        pass
    return "cpu", "int8"
