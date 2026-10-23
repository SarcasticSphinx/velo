#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
TESTDIR=$(mktemp -d -t breezeengine)
trap 'rm -f "$TESTDIR/engine-tests"; rmdir "$TESTDIR"' EXIT
xcrun swiftc -module-cache-path "${TMPDIR:-/tmp}/BreezeDictate-ModuleCache" \
  -framework AVFoundation -framework Speech Sources/Diagnostics.swift Sources/DictationEngine.swift Sources/ModernTranscriber.swift Sources/FnGesture.swift \
  Tests/EngineTests.swift -o "$TESTDIR/engine-tests"
"$TESTDIR/engine-tests"
