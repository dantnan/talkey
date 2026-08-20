#!/usr/bin/env python3
"""Thin client for talkey-daemon. Standard library only, so it starts fast.

    talkey-client.py <lang> <model> <wav> <outfile>

Writes the transcript to <outfile> as UTF-8 (empty file = nothing recognised).

Exit codes: 0 transcribed, 3 daemon unreachable, 4 request failed.

If nothing is listening the client starts the daemon detached and waits for it
to load the model, so the very first dictation after a reboot still works even
when the service or logon entry was removed.
"""
import os
import socket
import subprocess
import sys
import time

import talkey_cfg


def spawn_daemon():
    python = talkey_cfg.python_exe()
    daemon = os.path.join(talkey_cfg.BASE, "talkey-daemon.py")
    talkey_cfg.log("client", f"daemon not running, starting: {python} {daemon}")
    kwargs = {"cwd": talkey_cfg.BASE, "close_fds": True}
    if talkey_cfg.IS_WINDOWS:
        kwargs["creationflags"] = 0x00000008 | 0x08000000  # DETACHED | NO_WINDOW
    else:
        kwargs["start_new_session"] = True
        kwargs["stdout"] = subprocess.DEVNULL
        kwargs["stderr"] = subprocess.DEVNULL
    try:
        subprocess.Popen([python, daemon], **kwargs)
    except OSError as exc:
        # Nothing to print to: this runs windowless, so the log is the only
        # place this can surface.
        talkey_cfg.log("client", f"could not start daemon: {exc}")


def wait_for_daemon(cfg, deadline):
    while time.monotonic() < deadline:
        sock = talkey_cfg.client_socket(cfg)
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
    sock = talkey_cfg.client_socket(cfg)
    if sock is None:
        spawn_daemon()
        sock = wait_for_daemon(cfg, time.monotonic() + cfg.getint("daemon", "startup_timeout"))
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
        # Same reason: an uncaught traceback from a windowless process goes nowhere.
        import traceback

        talkey_cfg.log("client", "ERROR\n" + traceback.format_exc())
        sys.exit(4)
