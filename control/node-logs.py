#!/usr/bin/env python3
"""node-logs: keep the last lines of the node's logs where the control page can read them.

Follows `docker logs -f` for go-pulse and Prysm (as the repo owner, from a
systemd service) and writes the last MAX_LINES lines of each to
STATE_DIR/live/<container>.log every couple of seconds. The control page only
reads those files; it never gets Docker access.

File format: first line "#seq <number of the last line>", then the lines.
The page uses the sequence number to fetch only new lines.

Restarts its own follower when a container is recreated, and re-executes
itself when this file changes (so "Apply update" needs no sudo).
Standard library only.
"""
import collections
import os
import re
import subprocess
import sys
import tempfile
import threading
import time

STATE_DIR = os.environ.get("NODE_CONTROL_STATE", "/var/lib/node-control/state")
LIVE_DIR = os.path.join(STATE_DIR, "live")
CONTAINERS = os.environ.get("NODE_LOGS_CONTAINERS", "pulse-geth pulse-beacon").split()
MAX_LINES = 500
MAX_LINE_CHARS = 2000
WRITE_EVERY = 2.0
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
SELF = os.path.abspath(__file__)


class Follower:
    def __init__(self, name):
        self.name = name
        self.lines = collections.deque(maxlen=MAX_LINES)
        self.seq = 0
        self.dirty = True
        self.lock = threading.Lock()

    def add(self, raw):
        line = ANSI.sub("", raw.rstrip("\r\n"))[:MAX_LINE_CHARS]
        with self.lock:
            self.seq += 1
            self.lines.append(line)
            self.dirty = True

    def follow(self, stop):
        """Run `docker logs -f` until stopped; restart it when it ends."""
        first = True
        while not stop.is_set():
            # On a restart (container recreated), only take recent lines again.
            tail = str(MAX_LINES if first else 50)
            first = False
            try:
                p = subprocess.Popen(
                    ["docker", "logs", "-f", "--tail", tail, self.name],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors="replace",
                )
            except FileNotFoundError:
                self.add("[node-logs] docker not found")
                stop.wait(30)
                continue
            with p:  # closes the pipe and reaps the process
                for raw in p.stdout:
                    self.add(raw)
                    if stop.is_set():
                        break
                p.kill()
            stop.wait(3)

    def write(self):
        with self.lock:
            if not self.dirty:
                return
            text = f"#seq {self.seq}\n" + "\n".join(self.lines) + "\n"
            self.dirty = False
        fd, tmp = tempfile.mkstemp(dir=LIVE_DIR, prefix=".tmp.")
        with os.fdopen(fd, "w") as fh:
            fh.write(text)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(LIVE_DIR, f"{self.name}.log"))


def main():
    os.makedirs(LIVE_DIR, exist_ok=True)
    os.chmod(LIVE_DIR, 0o755)
    stop = threading.Event()
    followers = [Follower(n) for n in CONTAINERS]
    for f in followers:
        threading.Thread(target=f.follow, args=(stop,), daemon=True).start()
    started_mtime = os.path.getmtime(SELF)
    run_for = float(os.environ.get("NODE_LOGS_RUN_SECONDS", "0"))  # tests only
    t0 = time.time()
    while True:
        time.sleep(WRITE_EVERY)
        for f in followers:
            f.write()
        if run_for and time.time() - t0 > run_for:
            stop.set()
            return 0
        try:
            if os.path.getmtime(SELF) != started_mtime:  # updated by git pull
                os.execv(sys.executable, [sys.executable, SELF, *sys.argv[1:]])
        except OSError:
            pass


if __name__ == "__main__":
    sys.exit(main())
