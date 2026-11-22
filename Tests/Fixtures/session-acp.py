#!/usr/bin/env python3
"""Offline ACP session scenarios for the real AgentSessionModel."""
import json
import os
import pathlib
import subprocess
import sys
import time

SESSION = "offline-fixture"
pending_prompt = None
ignore_cancel = False


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


def mode_options(current, values):
    return [{"type": "select", "id": "permission-mode", "category": "mode", "name": "Mode",
             "currentValue": current, "options": [{"value": value, "name": value} for value in values]}]


claude = pathlib.Path(sys.argv[0]).name == "claude-fixture"
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    ident = request.get("id")
    if method == "initialize":
        respond(ident, {"protocolVersion": 1, "agentInfo": {"version": "offline"}, "agentCapabilities": {"loadSession": True}})
    elif method in ("session/new", "session/load"):
        if claude:
            assert method == "session/new" and "INITIAL_AGENT_MODE" not in os.environ
            options = mode_options("bypassPermissions", ["bypassPermissions", "auto", "default"])
        else:
            assert os.environ.get("INITIAL_AGENT_MODE") == "workspace-write"
            options = []
        respond(ident, {"sessionId": SESSION, "configOptions": options})
    elif method == "session/set_config_option":
        assert claude and request["params"] == {"sessionId": SESSION, "configId": "permission-mode", "value": "auto"}
        pathlib.Path("selected-mode").write_text(request["params"]["value"])
        respond(ident, {"configOptions": mode_options("auto", ["bypassPermissions", "auto", "default"])})
    elif method == "session/cancel":
        if pending_prompt and not ignore_cancel:
            respond(pending_prompt, {"stopReason": "cancelled"})
            pending_prompt = None
    elif method == "session/prompt":
        prompt = request["params"]["prompt"][0]["text"]
        ignore_cancel = "fixture:force-disconnect" in prompt
        if "fixture:permission-edit" in prompt:
            path = pathlib.Path("permission.txt")
            emit({"jsonrpc": "2.0", "id": "permission", "method": "session/request_permission",
                  "params": {"sessionId": SESSION,
                             "toolCall": {"toolCallId": "edit", "kind": "edit", "locations": [{"path": str(path.resolve())}]},
                             "options": [{"optionId": "allow", "kind": "allow_once", "name": "Allow once"}]}})
            answer = json.loads(sys.stdin.readline())
            if answer["result"]["outcome"].get("optionId") == "allow":
                path.write_text("allowed\n")
            respond(ident, {"stopReason": "end_turn"})
        elif "fixture:overflow" in prompt:
            pathlib.Path("edited.txt").write_text("ACP edit\n")
            update({"sessionUpdate": "tool_call", "toolCallId": "edit", "kind": "edit",
                    "locations": [{"path": "edited.txt"}], "status": "completed"})
            for index in range(499):
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
