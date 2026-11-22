#!/bin/bash
set -euo pipefail
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_RUNTIME="$HOME/Library/Application Support/Silica Workbench/ClaudeACP"
mkdir -p "$SILICA_RUNTIME"
cp "$SILICA_ROOT/Tools/ClaudeACP/package.json" "$SILICA_ROOT/Tools/ClaudeACP/package-lock.json" "$SILICA_RUNTIME/"
npm ci --include=optional --prefix "$SILICA_RUNTIME" --no-audit --no-fund
echo "Claude Code ACP 0.109.0 installed at: $SILICA_RUNTIME/node_modules/.bin/claude-agent-acp"
