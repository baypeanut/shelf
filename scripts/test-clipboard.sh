#!/bin/bash
# Runs the same synthetic test cases without SwiftPM/XCTest or a user pasteboard.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$PWD/.build/clipboard-tests"
mkdir -p "$OUT/ModuleCache"
COMPILER="$(xcrun --sdk macosx --find swiftc)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
printf 'import AppKit\nimport SwiftUI\n' > "$OUT/toolchain-probe.swift"
if ! python3 scripts/run-bounded.py 30 "$OUT/toolchain.log" "$COMPILER" -sdk "$SDK" -typecheck "$OUT/toolchain-probe.swift"; then
  echo "No compatible macOS SDK/compiler pair; select a matching Xcode toolchain." >&2
  exit 1
fi
SOURCES=()
for source in Sources/Shelf/*.swift; do
  [[ "$source" == */main.swift ]] || SOURCES+=("$source")
done
python3 scripts/run-bounded.py 180 "$OUT/compile.log" "$COMPILER" -sdk "$SDK" -module-cache-path "$OUT/ModuleCache" \
  -D STANDALONE_TESTS -parse-as-library \
  "${SOURCES[@]}" \
  Tests/ShelfTests/ClipboardWatcherTests.swift Tests/Standalone/ClipboardTestRunner.swift \
  -o "$OUT/clipboard-tests"
python3 scripts/run-bounded.py 120 "$OUT/test.log" "$OUT/clipboard-tests"
