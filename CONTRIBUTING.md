# Contributing to Shelf

Use a current Xcode installation on macOS 14 or later. Keep changes native to macOS and preserve keyboard access, VoiceOver labels, light/dark appearance and existing data safety.

Run `swift test`, `swift scripts/check-strings.swift`, the publication audit and the app build before proposing a change. Include a synthetic reproduction and relevant behavioral tests for correctness/security fixes. UI verification should use the isolated harness and fictional content. Do not include personal clipboard data or preferences.

Preserve the component notices distributed with optional dependencies. Changes to networking, capture defaults, storage or permissions must update `PRIVACY.md` and receive focused security review. Release claims must reflect actual signing, notarization and test evidence.

The [testing guide](docs/testing-guide.md) covers focused reruns, optimized tests, standalone runners and the isolated UI harness. Use the [build guide](docs/build-guide.md) when checking packaged startup or optional model assets.
