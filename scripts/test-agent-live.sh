#!/bin/bash
set -euo pipefail
SILICA_AGENT="${AGENT:-codex}"
case "$SILICA_AGENT" in
    codex) SILICA_OPT_IN="${RUN_LIVE_AGENT_TESTS:-${RUN_LIVE_CODEX_TESTS:-}}" ;;
    claude) SILICA_OPT_IN="${RUN_LIVE_AGENT_TESTS:-}" ;;
    *) echo 'AGENT must be codex or claude' >&2; exit 2 ;;
esac
if [[ "$SILICA_OPT_IN" != 1 ]]; then
    echo "Explicit opt-in required: RUN_LIVE_AGENT_TESTS=1 AGENT=$SILICA_AGENT bash scripts/test-agent-live.sh" >&2
    exit 2
fi
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_TESTS=$(mktemp -d "${TMPDIR:-/tmp}/silica-agent-live.XXXXXX")
trap 'rm -rf "$SILICA_TESTS"' EXIT
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPJSON.swift" \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPTransport.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentTurn.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentKind.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentPaths.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentProcessTree.swift" \
    "$SILICA_ROOT/Tests/ACPLiveSmoke.swift" \
    -o "$SILICA_TESTS/agent-live"
AGENT="$SILICA_AGENT" "$SILICA_TESTS/agent-live" "$SILICA_ROOT"
