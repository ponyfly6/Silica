#!/usr/bin/env python3
"""Deterministic JSON-RPC fixture, never calls a model or touches a project."""
import json
import sys

pending_permission = None

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\r\n")
    sys.stdout.flush()

for line in sys.stdin:
    request = json.loads(line)
    method = request.get("method")
    if method is None and pending_permission is not None:
        emit({"jsonrpc": "2.0", "id": pending_permission, "result": request.get("result")})
        pending_permission = None
        continue
    ident = request.get("id")
    if method == "hang":
        continue
    if method == "broken-eof":
        sys.stdout.write('{"jsonrpc":')
        sys.stdout.flush()
        break
    if method == "notify":
        for number in range(20):
            emit({"jsonrpc": "2.0", "method": "ordered", "params": {"sequence": number}})
    if method == "permission":
        pending_permission = ident
        emit({"jsonrpc": "2.0", "id": "agent-request", "method": "session/request_permission", "params": {"sessionId": "fixture"}})
        continue
    emit({"jsonrpc": "2.0", "id": ident, "result": request.get("params", {})})
