#!/usr/bin/env python3
"""Offline ACP session scenarios for the real AgentSessionModel."""
import json
import pathlib
import subprocess
import sys
import time

SESSION = "offline-fixture"
pending_prompt = None


def emit(value):
    print(json.dumps(value), flush=True)


def respond(ident, result):
    emit({"jsonrpc": "2.0", "id": ident, "result": result})


def update(value):
    emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": SESSION, "update": value}})


def start_writer():
    code = """import pathlib,signal,time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
print('ready', flush=True)
n = 0
deadline = time.monotonic() + 30
while time.monotonic() < deadline:
    n += 1
    pathlib.Path('heartbeat').write_text(str(n))
    time.sleep(.02)
"""
    child = subprocess.Popen([sys.executable, "-u", "-c", code], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    child.stdout.readline()
    pathlib.Path("writer.pid").write_text(str(child.pid))


for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    ident = request.get("id")
    if method == "initialize":
        respond(ident, {"protocolVersion": 1, "agentInfo": {"version": "offline"}, "agentCapabilities": {"loadSession": True}})
    elif method in ("session/new", "session/load"):
        respond(ident, {"sessionId": SESSION, "configOptions": []})
    elif method == "session/cancel":
        if pending_prompt:
            respond(pending_prompt, {"stopReason": "cancelled"})
            pending_prompt = None
    elif method == "session/prompt":
        prompt = request["params"]["prompt"][0]["text"]
        if "fixture:overflow" in prompt:
            for index in range(500):
                update({"sessionUpdate": "tool_call", "toolCallId": str(index), "kind": "read", "status": "completed"})
                if index % 25 == 0:
                    time.sleep(.002)
            update({"sessionUpdate": "tool_call", "toolCallId": "hidden-command", "status": "failed",
                    "_meta": {"terminal_info": {"terminal_id": "hidden"}}})
            respond(ident, {"stopReason": "end_turn"})
            time.sleep(.25)
            pathlib.Path("late.txt").write_text("written before terminal exit\n")
            update({"sessionUpdate": "tool_call_update", "toolCallId": "hidden-command",
                    "_meta": {"terminal_exit": {"exit_code": 7}}})
        else:
            start_writer()
            update({"sessionUpdate": "tool_call", "toolCallId": "writer", "status": "in_progress",
                    "_meta": {"terminal_info": {"terminal_id": "writer", "cwd": str(pathlib.Path.cwd())}}})
            if "fixture:disconnect" in prompt:
                time.sleep(.3)
                break
            if "fixture:wait-after-response" in prompt:
                respond(ident, {"stopReason": "end_turn"})
            else:
                pending_prompt = ident
