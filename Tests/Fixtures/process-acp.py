#!/usr/bin/env python3
"""Disposable process-tree regressions. All paths are supplied by the tests."""
import json
import signal
import subprocess
import sys
import time


def emit(ident, result):
    print(json.dumps({"jsonrpc": "2.0", "id": ident, "result": result}), flush=True)


def writer(path):
    code = """import pathlib,signal,sys,time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
p = pathlib.Path(sys.argv[1])
print('ready', flush=True)
n = 0
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    n += 1
    p.write_text(str(n))
    time.sleep(.02)
"""
    child = subprocess.Popen(
        [sys.executable, "-u", "-c", code, path],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True,
    )
    child.stdout.readline()
    return child.pid


signal.signal(signal.SIGTERM, signal.SIG_IGN)
spawn_on_eof = None
for line in sys.stdin:
    request = json.loads(line)
    method = request["method"]
    path = request.get("params", {}).get("path", "")
    if method == "spawn-on-eof":
        spawn_on_eof = path
        emit(request["id"], {})
    else:
        emit(request["id"], {"pid": writer(path)})
        if method == "orphan":
            # Allow live tracking to observe the child before its parent exits.
            time.sleep(.3)
            break
        if method == "block-stdin":
            time.sleep(60)
if spawn_on_eof:
    pid = writer(spawn_on_eof)
    with open(spawn_on_eof + ".pid", "w") as handle:
        handle.write(str(pid))
    time.sleep(.3)
