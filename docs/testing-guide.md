# Testing Shelf

Use fictional content, disposable preferences, named pasteboards and test-owned folders. Keep commands and evidence reproducible without opening a personal clipboard library or changing system screenshot settings.

## Run native tests

```sh
swift test
```

The Swift package includes clipboard tests and the larger ImageHistoryTests suite. Save local output under the ignored `local/` directory when you need a log. A passing test run applies to that source revision and toolchain.

## Check optimized behavior

```sh
swift test -c release
```

Optimization can change timing and expose assumptions. Compare failures by test name rather than expecting debug and release test counts to match, since some instrumentation is debug-only.
