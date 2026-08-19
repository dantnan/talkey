#!/usr/bin/env python3
"""Thin client for dictate-daemon. Standard library only, so it starts fast.

    dictate-client.py <lang> <model> <wav> <outfile>

Writes the transcript to <outfile> as UTF-8 (empty file = nothing recognised).

Exit codes: 0 transcribed, 3 daemon unreachable, 4 request failed.

If nothing is listening the client starts the daemon detached and waits for it
to load the model, so the very first dictation after a reboot still works even
when the logon shortcut was removed.
"""
import os
import socket
import subprocess
import sys
import time

import talkey_cfg

DETACHED = 0x00000008  # DETACHED_PROCESS
NO_WINDOW = 0x08000000  # CREATE_NO_WINDOW


def connect(host, port, timeout=2.0):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    try:
        sock.connect((host, port))
    except OSError:
        sock.close()
        return None
    return sock


def spawn_daemon():
    # The venv sits next to this file; sys.executable is only a fallback for the
    # case where somebody ran the client with a different interpreter.
    python = os.path.join(talkey_cfg.BASE, "venv", "Scripts", "pythonw.exe")
    if not os.path.exists(python):
        python = sys.executable
    daemon = os.path.join(talkey_cfg.BASE, "dictate-daemon.py")
    talkey_cfg.log("client", f"daemon not running, starting: {python} {daemon}")
    try:
        subprocess.Popen(
            [python, daemon],
            cwd=talkey_cfg.BASE,
            creationflags=DETACHED | NO_WINDOW,
            close_fds=True,
        )
    except OSError as exc:
        # Nothing to print to: pythonw has no console, so the log is the only
        # place this can surface.
        talkey_cfg.log("client", f"could not start daemon: {exc}")


def wait_for_daemon(host, port, deadline):
    while time.monotonic() < deadline:
        sock = connect(host, port)
        if sock:
            return sock
        time.sleep(1.0)
    return None


def main():
    if len(sys.argv) != 5:
        print(__doc__, file=sys.stderr)
        return 2
    lang, model, wav, outfile = sys.argv[1:5]

    cfg = talkey_cfg.load()
    host = cfg.get("daemon", "host")
    port = cfg.getint("daemon", "port")

    sock = connect(host, port)
    if sock is None:
        spawn_daemon()
        deadline = time.monotonic() + cfg.getint("daemon", "startup_timeout")
        sock = wait_for_daemon(host, port, deadline)
    if sock is None:
        talkey_cfg.log("client", "daemon never came up")
        return 3

    try:
        sock.settimeout(600)
        sock.sendall(f"{lang}\t{model}\t{wav}\n".encode("utf-8"))
        sock.shutdown(socket.SHUT_WR)
        buf = b""
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buf += chunk
    except OSError as exc:
        talkey_cfg.log("client", f"request failed: {exc}")
        return 4
    finally:
        sock.close()

    with open(outfile, "w", encoding="utf-8") as fh:
        fh.write(buf.decode("utf-8", "replace"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:
        # Same reason: an uncaught traceback under pythonw goes nowhere.
        import traceback

        talkey_cfg.log("client", "ERROR\n" + traceback.format_exc())
        sys.exit(4)
