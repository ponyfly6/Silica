#!/bin/bash
set -euo pipefail
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_TESTS=$(mktemp -d "${TMPDIR:-/tmp}/silica-agent-tests.XXXXXX")
trap 'rm -rf "$SILICA_TESTS"' EXIT
cp "$SILICA_ROOT/Tests/Fixtures/fake-acp.py" "$SILICA_TESTS/fake-acp"
cp "$SILICA_ROOT/Tests/Fixtures/process-acp.py" "$SILICA_TESTS/process-acp"
chmod +x "$SILICA_TESTS/fake-acp" "$SILICA_TESTS/process-acp"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPJSON.swift" \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPTransport.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentTurn.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentKind.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentPaths.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentProcessTree.swift" \
    "$SILICA_ROOT/Silica/Views/WorkspaceLayout.swift" \
    "$SILICA_ROOT/Tests/AgentCoreTests.swift" \
    -o "$SILICA_TESTS/agent-tests"
"$SILICA_TESTS/agent-tests" "$SILICA_TESTS/fake-acp" "$SILICA_TESTS/process-acp"
