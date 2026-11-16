#!/bin/bash
set -euo pipefail
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_RUNTIME="$HOME/Library/Application Support/Silica Workbench/CodexACP"
mkdir -p "$SILICA_RUNTIME"
cp "$SILICA_ROOT/Tools/CodexACP/package.json" "$SILICA_ROOT/Tools/CodexACP/package-lock.json" "$SILICA_RUNTIME/"
npm ci --prefix "$SILICA_RUNTIME" --no-audit --no-fund
echo "Codex ACP 2.6.0 installed at: $SILICA_RUNTIME/node_modules/.bin/codex-acp"
