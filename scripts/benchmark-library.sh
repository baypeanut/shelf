#!/bin/bash
# Builds synthetic libraries in a temporary folder and prints main-thread
# timings for saving, searching, opening and reloading. Opens no windows and
# reads no personal data. Usage: scripts/benchmark-library.sh [sizes]
set -euo pipefail
cd "$(dirname "$0")/.."
SHELF_LIBRARY_BENCHMARK="${1:-5000,50000}" swift test -c release --filter LibraryBenchmarkTests 2>&1 |
  sed -n '/^## Library benchmark/,/^Largest tables/p;/error:/p;/failed/p'
