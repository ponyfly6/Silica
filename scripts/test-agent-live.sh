#!/bin/bash
set -euo pipefail
if [[ "${RUN_LIVE_CODEX_TESTS:-}" != "1" ]]; then
    echo 'Explicit opt-in required: RUN_LIVE_CODEX_TESTS=1 bash scripts/test-agent-live.sh'
    exit 2
fi
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_TESTS=$(mktemp -d "${TMPDIR:-/tmp}/silica-agent-live.XXXXXX")
trap 'rm -rf "$SILICA_TESTS"' EXIT
SILICA_ADAPTER="${SILICA_CODEX_ACP:-$SILICA_ROOT/Tools/CodexACP/node_modules/.bin/codex-acp}"
if [[ ! -x "$SILICA_ADAPTER" && -z "${SILICA_CODEX_ACP:-}" ]]; then
    SILICA_ADAPTER="$HOME/Library/Application Support/Silica Workbench/CodexACP/node_modules/.bin/codex-acp"
fi
if [[ ! -x "$SILICA_ADAPTER" ]]; then
    echo 'Install the adapter first: bash scripts/install-codex-acp.sh' >&2
    exit 1
fi
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPJSON.swift" \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPTransport.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentTurn.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/TurnSnapshot.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentProcessTree.swift" \
    "$SILICA_ROOT/Silica/Models/GitIgnore.swift" \
    "$SILICA_ROOT/Tests/ACPLiveSmoke.swift" \
    -o "$SILICA_TESTS/agent-live"
"$SILICA_TESTS/agent-live" "$SILICA_ADAPTER"
