#!/bin/bash
set -euo pipefail

REVIEW_ROOT=$(cd "$(dirname "$0")/.." && pwd)
REVIEW_TEMP=$(mktemp -d "${TMPDIR:-/tmp}/silica-review-tests.XXXXXX")
trap 'rm -rf "$REVIEW_TEMP"' EXIT

xcrun swiftc -O -parse-as-library \
    "$REVIEW_ROOT/Silica/Review/UnifiedDiff.swift" \
    "$REVIEW_ROOT/Silica/Review/GitDiffEngine.swift" \
    "$REVIEW_ROOT/Tests/ReviewCoreTests.swift" \
    -o "$REVIEW_TEMP/review-tests"
"$REVIEW_TEMP/review-tests"
