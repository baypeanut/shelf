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

## Build the UI harness

```sh
bash scripts/build-ui-tests.sh
open "build/Shelf UI Test.app"
```

The separate harness uses synthetic fixtures and an isolated bundle identifier. Quit an existing harness before rebuilding it. Generated observations stay under `local/validation/current/`.

## Reuse a QA session

The harness accepts `--qa-session` followed by a UUID to resume an isolated profile across process restarts. Use a fresh UUID for an independent scenario, then reopen the same session to check persistence. Keep the session identifier and fixture data local.

## Validate translations

```sh
swift scripts/check-strings.swift
```

Run this after changing localized strings. Keep source keys, all translation catalogs and any formatting placeholders consistent. A catalog check does not establish that every translation fits its native control.
