#!/bin/bash
set -euo pipefail
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_TESTS=$(mktemp -d "${TMPDIR:-/tmp}/silica-agent-tests.XXXXXX")
trap 'rm -rf "$SILICA_TESTS"' EXIT
cp "$SILICA_ROOT/Tests/Fixtures/fake-acp.py" "$SILICA_TESTS/fake-acp"
cp "$SILICA_ROOT/Tests/Fixtures/process-acp.py" "$SILICA_TESTS/process-acp"
chmod +x "$SILICA_TESTS/fake-acp" "$SILICA_TESTS/process-acp"
SILICA_DERIVED="$SILICA_ROOT/.derivedData"
if ! xcodebuild -scheme Silica -project "$SILICA_ROOT/Silica.xcodeproj" -configuration Debug \
    -derivedDataPath "$SILICA_DERIVED" -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -skipPackagePluginValidation \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build > "$SILICA_TESTS/build.log" 2>&1; then
    cat "$SILICA_TESTS/build.log"
    exit 1
fi
SILICA_PRODUCTS="$SILICA_DERIVED/Build/Products/Debug"
xcrun swiftc -swift-version 6 -strict-concurrency=complete -O -parse-as-library \
    -I "$SILICA_PRODUCTS" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-markdown/Sources/CAtomic/include" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-cmark/src/include" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-cmark/extensions/include" \
    "$SILICA_PRODUCTS"/{Markdown,CAtomic,cmark-gfm,cmark-gfm-extensions}.o \
    "$SILICA_ROOT/Silica/Agent/Models/AgentMarkdown.swift" \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPJSON.swift" \
    "$SILICA_ROOT/Silica/Agent/Protocol/ACPTransport.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentPrompt.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentUsage.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentChanges.swift" \
    "$SILICA_ROOT/Silica/Agent/Models/AgentTurn.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentKind.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentPaths.swift" \
    "$SILICA_ROOT/Silica/Agent/Support/AgentProcessTree.swift" \
    "$SILICA_ROOT/Silica/Views/WorkspaceLayout.swift" \
    "$SILICA_ROOT/Tests/AgentCoreTests.swift" \
    -o "$SILICA_TESTS/agent-tests"
"$SILICA_TESTS/agent-tests" "$SILICA_TESTS/fake-acp" "$SILICA_TESTS/process-acp"
