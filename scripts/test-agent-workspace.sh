#!/bin/bash
set -euo pipefail
SILICA_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SILICA_TESTS=$(mktemp -d "${TMPDIR:-/tmp}/silica-workspace-tests.XXXXXX")
trap 'rm -rf "$SILICA_TESTS"' EXIT
SILICA_DERIVED="$SILICA_ROOT/.derivedData"
if ! xcodebuild -scheme Silica -project "$SILICA_ROOT/Silica.xcodeproj" -configuration Debug \
    -derivedDataPath "$SILICA_DERIVED" -disableAutomaticPackageResolution \
    -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates \
    CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build > "$SILICA_TESTS/build.log" 2>&1; then
    cat "$SILICA_TESTS/build.log"
    exit 1
fi
SILICA_PRODUCTS="$SILICA_DERIVED/Build/Products/Debug"
cp "$SILICA_ROOT/Tests/Fixtures/session-acp.py" "$SILICA_TESTS/session-acp"
chmod +x "$SILICA_TESTS/session-acp"
# Import and link the actual app implementation, without launching its SwiftUI
# entry point or connecting to an account. AppKit views remain in this test process.
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -I "$SILICA_PRODUCTS" -F "$SILICA_PRODUCTS" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-markdown/Sources/CAtomic/include" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-cmark/src/include" \
    -I "$SILICA_DERIVED/SourcePackages/checkouts/swift-cmark/extensions/include" \
    "$SILICA_ROOT/Tests/AgentWorkspaceTests.swift" \
    "$SILICA_PRODUCTS/Silica.app/Contents/MacOS/Silica.debug.dylib" \
    -Xlinker -rpath -Xlinker "$SILICA_PRODUCTS" \
    -Xlinker -rpath -Xlinker "$SILICA_PRODUCTS/Silica.app/Contents/MacOS" \
    -o "$SILICA_TESTS/agent-workspace-tests"
"$SILICA_TESTS/agent-workspace-tests" "$SILICA_TESTS/session-acp"
