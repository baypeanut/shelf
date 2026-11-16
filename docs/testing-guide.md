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

## Render every screen to PNG files

```sh
bash scripts/render-screens.sh local/validation/screens en tr
```

The renderer builds the harness, then draws each screen into the folder you name: the shelves, Library, previews, markup and crop, every Settings pane, Actions, the pickers and the confirmation alerts, in light and dark appearance, one folder per language and appearance. Languages default to `en` and `tr`; any translation in `Sources/Shelf/Resources` can be named. It shows no window, uses its own temporary fixtures and works while the screen is locked. Set `SHELF_RENDER_SKIP_BUILD=1` to reuse the harness already built.

Views draw themselves in the process, so the files differ from the screen in known ways. Materials that blend with the desktop come out flat, window shadows are missing, an inactive window's sidebar selection is drawn without its label, and hover states never appear. Menus cannot be drawn this way: `menus.txt` lists the menu bar menu's titles, order, state and key equivalents instead, with `status-item.png` for its icon. `render-<language>.txt` names every file written and any screen that could not be drawn. Read the PNG files after an interface change, and check the longer translations for truncation.

## Reuse a QA session

The harness accepts `--qa-session` followed by a UUID to resume an isolated profile across process restarts. Use a fresh UUID for an independent scenario, then reopen the same session to check persistence. Keep the session identifier and fixture data local.

## Measure library performance

```sh
bash scripts/benchmark-library.sh 5000,50000
```

The benchmark builds fictional libraries of the given sizes in a temporary folder through the store's own API, then prints main-thread timings for opening the store, saving each kind of item, reloading the shelves and searching, with the database size. It runs optimized, opens no windows and is skipped by `swift test`. Compare runs on the same Mac; a 50,000-item run takes a few minutes.

```sh
bash scripts/benchmark-library.sh upgrade 50000
```

The upgrade form writes a library the way the previous build stored it, opens it with the current one and reports the first launch with its snapshot, saves made while the search index is built in the background, and the file size before and after.

## Validate translations

```sh
swift scripts/check-strings.swift
```

Run this after changing localized strings. Keep source keys, all translation catalogs and any formatting placeholders consistent. A catalog check does not establish that every translation fits its native control.

## Check publication safety

```sh
python3 scripts/test-audit-public.py
python3 scripts/test-release-version.py
python3 scripts/audit-public.py
python3 scripts/check-secrets.py
```

The publication audit rejects private artifact paths and high-confidence secret formats. The pinned secret scanner also checks public Git history and verifies its detector with a positive control.

## Record what was tested

Include source revision, macOS version, architecture, toolchain, commands and observed outcomes. Distinguish native action tests from physical pointer or VoiceOver checks. Store logs and screenshots locally, and record release limits alongside the results in [Validation](macos-validation.md).
