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


def select_option(ident, category, current, values):
    return {"type": "select", "id": ident, "category": category, "name": category,
            "currentValue": current, "options": [{"value": v, "name": v.title()} for v in values]}


def levels():
    return ["medium", "low"] if model == "small" else ["medium", "low", "high"]


def config_options():
    options = [select_option("model", "model", model, ["standard", "small"]),
               select_option(effort_id, "thought_level", effort, levels())]
    if claude:
        options.append(select_option("permission-mode", "mode", mode, ["bypassPermissions", "auto", "default"]))
    return options


def record(call):
    with open("config-calls", "a") as log:
        print(call, file=log)


claude = pathlib.Path(sys.argv[0]).name == "claude-fixture"
effort_id = "effort" if claude else "reasoning_effort"
for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    ident = request.get("id")
    if method == "initialize":
        replacement = pathlib.Path("replacement-session").exists()
        if replacement:
            SESSION = "replacement"
        respond(ident, {"protocolVersion": 1, "agentInfo": {"version": "offline"}, "agentCapabilities": {
            "loadSession": not replacement, "promptCapabilities": {"image": True, "embeddedContext": True}}})
        if not replacement:
            emit({"jsonrpc": "2.0", "method": "_auth/status_update",
                  "params": {"authStatus": {"kind": "authenticated", "label": "Fixture", "account": {"plan": "team"}}}})
    elif method in ("session/new", "session/load"):
        assert os.environ.get("INITIAL_AGENT_MODE") == (None if claude else "workspace-write")
        record(method)
        model, effort, mode = "standard", "medium", "bypassPermissions"
        if method == "session/new" and not replacement:
            update({"sessionUpdate": "available_commands_update", "availableCommands": [
                {"name": "review", "description": "Review a file", "input": {"hint": "path"}}]})
            update({"sessionUpdate": "session_info_update", "title": "Fixture chat"})
            update({"sessionUpdate": "usage_update", "used": 17000, "size": 1000000})
        elif method == "session/load":
            update({"sessionUpdate": "agent_message_chunk", "content": {"text": "replayed message"}})
            update({"sessionUpdate": "tool_call", "toolCallId": "replay", "kind": "read"})
        respond(ident, {"sessionId": SESSION, "configOptions": config_options()})
    elif method == "session/set_config_option":
        params = request["params"]
        assert params["sessionId"] == SESSION
        key, value = params["configId"], params["value"]
        record(f"{key}={value}")
        rejection = pathlib.Path("reject-option")
        if rejection.exists():
            if rejection.read_text() == "unconfirmed":
                respond(ident, {"configOptions": config_options()})
            else:
                emit({"jsonrpc": "2.0", "id": ident, "error": {"code": -32602, "message": "Fixture rejected option"}})
            continue
        if key == "permission-mode":
            assert claude and value == "auto"
            mode = value
            pathlib.Path("selected-mode").write_text(value)
        elif key == "model":
            assert value in ["standard", "small"]
            model = value
            if effort not in levels():
                effort = "medium"
        else:
            assert key == effort_id and value in levels()
            effort = value
        respond(ident, {"configOptions": config_options()})
    elif method == "session/cancel":
        if pending_prompt and not ignore_cancel:
            respond(pending_prompt, {"stopReason": "cancelled"})
            pending_prompt = None
    elif method == "session/prompt":
        pathlib.Path("prompt.json").write_text(json.dumps(request["params"]))
        prompt = request["params"]["prompt"][0]["text"]
        ignore_cancel = "fixture:force-disconnect" in prompt
        if "fixture:reject" in prompt:
            emit({"jsonrpc": "2.0", "id": ident, "error": {"code": -32602, "message": "Fixture rejected prompt"}})
        elif "fixture:permission-edit" in prompt:
            path = pathlib.Path("permission.txt")
            emit({"jsonrpc": "2.0", "id": "permission", "method": "session/request_permission",
                  "params": {"sessionId": SESSION,
                             "toolCall": {"toolCallId": "edit", "kind": "edit", "locations": [{"path": str(path.resolve())}]},
                             "options": [{"optionId": "allow", "kind": "allow_once", "name": "Allow once"}]}})
            answer = json.loads(sys.stdin.readline())
            if answer["result"]["outcome"].get("optionId") == "allow":
                path.write_text("allowed\n")
            respond(ident, {"stopReason": "end_turn"})
        elif "fixture:summary" in prompt:
            update({"sessionUpdate": "session_info_update", "title": "Edited file"})
            update({"sessionUpdate": "session_info_update"})
            update({"sessionUpdate": "usage_update", "used": 16000, "size": 1000000, "cost": {"amount": 0.01, "currency": "USD"}})
            update({"sessionUpdate": "usage_update", "used": 15062, "size": 1000000, "cost": {"amount": 0.03, "currency": "USD"},
                    "_meta": {"_claude/model": "fixture-model", "_claude/origin": "main",
                              "_claude/rateLimit": {"status": "allowed", "rateLimitType": "five_hour", "utilization": 0.1, "resetsAt": 12345}}})
            update({"sessionUpdate": "agent_message_chunk", "content": {"text": "Creating the file."}})
            update({"sessionUpdate": "tool_call", "toolCallId": "write", "kind": "edit", "status": "completed",
                    "content": [{"type": "diff", "path": "new.txt", "newText": "alpha\nbeta\n"}]})
            pathlib.Path("new.txt").write_text("alpha\nbeta\n")
            update({"sessionUpdate": "agent_message_chunk", "content": {"text": "Created [new.txt](new.txt:2)."}})
            emit({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "foreign", "update": {
                "sessionUpdate": "usage_update", "used": 99, "size": 100}}})
            respond(ident, {"stopReason": "end_turn", "usage": {"inputTokens": 2, "outputTokens": 4, "cachedReadTokens": 9273,
                                                               "cachedWriteTokens": 5783, "totalTokens": 15062},
                            "_meta": {"quota": {"token_count": {"reasoningOutputTokens": 0}, "model_usage": []}}})
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
