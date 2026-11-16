#!/bin/bash
# Builds synthetic libraries in a temporary folder and prints main-thread
# timings for saving, searching, opening and reloading. Opens no windows and
# reads no personal data.
# Usage: scripts/benchmark-library.sh [sizes]
#        scripts/benchmark-library.sh upgrade [size]   a library from the previous build, upgraded
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-}" == upgrade ]]; then
  SHELF_LIBRARY_UPGRADE_BENCHMARK="${2:-50000}" swift test -c release --filter LibraryBenchmarkTests/testUpgradeBenchmark 2>&1 |
    sed -n '/^## Upgrade benchmark/,/^Database file/p;/error:/p;/failed/p'
  exit
fi
SHELF_LIBRARY_BENCHMARK="${1:-5000,50000}" swift test -c release --filter LibraryBenchmarkTests/testLibraryBenchmark 2>&1 |
  sed -n '/^## Library benchmark/,/^Largest tables/p;/error:/p;/failed/p'
