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

## Reproduce a focused failure

```sh
swift test --filter PreviewWindowTests
```

Start with the failing suite to shorten the feedback cycle, then run the relevant broader tests after a correction. Preserve the synthetic reproduction and the expected user-visible behavior in a regression.

## Use standalone runners

```sh
bash scripts/test-clipboard.sh
bash scripts/test-history.sh
```

These scripts compile standalone runners against the native sources. They are useful for investigating test-runner or toolchain differences. They do not replace verification of the packaged application.
