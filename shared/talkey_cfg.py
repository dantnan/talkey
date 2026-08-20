#!/usr/bin/env python3
"""Shared config, paths, logging and socket plumbing for Talkey.

Every script lives next to config.ini, so the install directory is simply the
directory this module was imported from. Nothing here imports a third-party
package: the client must stay fast to start.

Windows and Linux differ in exactly one interesting way, the IPC socket. Linux
gets an AF_UNIX socket in the runtime dir, which the filesystem can restrict to
one user; Windows has no such thing available to plain Python, so it gets a
loopback TCP port instead.
"""
import configparser
import os
import socket
import sys

BASE = os.path.dirname(os.path.abspath(__file__))
CFG_PATH = os.path.join(BASE, "config.ini")
IS_WINDOWS = os.name == "nt"

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
    if IS_WINDOWS:
        root = os.environ.get("TEMP") or BASE
    else:
        root = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    d = os.path.join(root, "talkey")
    os.makedirs(d, exist_ok=True)
    return d


def socket_path():
    """AF_UNIX socket path. Linux only."""
    root = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    return os.path.join(root, "talkey.sock")


def python_exe(windowless=True):
    """The venv interpreter that sits next to this file.

    sys.executable is only a fallback for someone running a script by hand with
    a different interpreter.
    """
    if IS_WINDOWS:
        name = "pythonw.exe" if windowless else "python.exe"
        candidate = os.path.join(BASE, "venv", "Scripts", name)
    else:
        candidate = os.path.join(BASE, "venv", "bin", "python")
    return candidate if os.path.exists(candidate) else sys.executable


def server_socket(cfg):
    """Bind and return the listening socket for the daemon.

    Deliberately no SO_REUSEADDR: a second copy should fail to bind and exit
    quietly rather than two daemons fighting over the same endpoint.
    """
    if IS_WINDOWS:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.bind((cfg.get("daemon", "host"), cfg.getint("daemon", "port")))
        return srv, f"{cfg.get('daemon', 'host')}:{cfg.getint('daemon', 'port')}"

    path = socket_path()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    if os.path.exists(path):
        # Stale socket from a killed daemon: nobody is listening, so connecting
        # to it fails and it is safe to replace. A live one is still held by its
        # owner, and the bind below will refuse.
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(0.5)
        try:
            probe.connect(path)
        except OSError:
            os.unlink(path)
        else:
            probe.close()
            raise OSError(f"another daemon is already listening on {path}")
        finally:
            probe.close()
    srv.bind(path)
    os.chmod(path, 0o600)
    return srv, path


def client_socket(cfg, timeout=2.0):
    """Connect to the daemon, or return None when nothing is listening."""
    if IS_WINDOWS:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        target = (cfg.get("daemon", "host"), cfg.getint("daemon", "port"))
    else:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        target = socket_path()
    sock.settimeout(timeout)
    try:
        sock.connect(target)
    except OSError:
        sock.close()
        return None
    return sock


def log(name, msg):
    """Append a line to <install dir>/<name>.log, truncating past 1 MB."""
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


def trim_memory():
    """Hand freed pages back to the OS after dropping a model.

    gc.collect() alone leaves them in this process's heap on both platforms.
    """
    import ctypes

    try:
        if IS_WINDOWS:
            kernel32 = ctypes.windll.kernel32
            kernel32.SetProcessWorkingSetSize(
                kernel32.GetCurrentProcess(), ctypes.c_size_t(-1), ctypes.c_size_t(-1)
            )
        else:
            ctypes.CDLL("libc.so.6").malloc_trim(0)
    except (AttributeError, OSError):
        pass
