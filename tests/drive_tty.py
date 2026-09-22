#!/usr/bin/env python3
"""Run a command under a pseudo-terminal and type at it.

The menus and prompts only exist when there is a real terminal, so testing
them needs one. Usage:

    drive_tty.py <confdir> <key>[,<key>...] -- <command> [args...]

Keys are Python string escapes: 'up', 'down', '\\r', 'q', or literal text.
Prints everything the program drew, with escape sequences stripped.
"""
import os
import pty
import re
import select
import signal
import sys
import time

KEYS = {"up": b"\x1b[A", "down": b"\x1b[B", "esc": b"\x1b", "enter": b"\r"}
ANSI = re.compile(rb"\x1b\[[0-9;?]*[A-Za-z]")


def main():
    confdir, keyspec = sys.argv[1], sys.argv[2]
    cmd = sys.argv[sys.argv.index("--") + 1:]
    keys = [KEYS.get(k, k.encode().decode("unicode_escape").encode())
            for k in keyspec.split(",") if k]

    env = dict(os.environ, XRAY_TUN_CONFDIR=confdir, NO_COLOR="1", TERM="dumb")
    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(cmd[0], cmd, env)
        os._exit(127)

    out = b""
    time.sleep(0.5)
    for k in keys:
        os.write(fd, k)
        time.sleep(0.2)
        while select.select([fd], [], [], 0.05)[0]:
            try:
                out += os.read(fd, 65536)
            except OSError:
                break
    deadline = time.time() + 5
    done = False
    while time.time() < deadline:
        if select.select([fd], [], [], 0.2)[0]:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        elif os.waitpid(pid, os.WNOHANG)[0]:
            done = True
            break
    # Never block waiting for the child. A prompt still expecting input would
    # otherwise hang the whole suite, which is exactly what a test of prompts
    # must not do. Past the deadline, kill it.
    if not done:
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.kill(pid, sig)
            except ProcessLookupError:
                break
            for _ in range(20):
                if os.waitpid(pid, os.WNOHANG)[0]:
                    done = True
                    break
                time.sleep(0.05)
            if done:
                break
    try:
        os.close(fd)
    except OSError:
        pass
    sys.stdout.write(ANSI.sub(b"", out).decode("utf-8", "replace"))


if __name__ == "__main__":
    main()
