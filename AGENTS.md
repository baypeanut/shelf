# Shelf

Shelf is a native macOS clipboard utility.

- Use the `Shelf` package, `com.baypeanut.Shelf` bundle identifier and Shelf application support directory.
- Keep the application macOS-only. Do not add other platform shipping targets.
- Preserve the component notices required by optional dependencies.
- Test with synthetic content, disposable preferences, named pasteboards and test-owned folders. Never use personal clipboard history or change system screenshot settings during tests.
- Run relevant native Swift tests, build the app, verify its bundle and scan for secrets before publication.
- Keep local data, build products, credentials and test evidence out of Git.
- Document actual results and release limits. Do not claim distribution signing, notarization or App Store approval without evidence.
