# Shelf security

Shelf is a local macOS clipboard application. Treat clipboard history as potentially confidential, even when files are restricted to your account. It is not a password manager or an encrypted vault.

## Report an issue

Use the repository's private security reporting channel when available. Otherwise open an issue requesting a private reporting route without posting the vulnerability, personal clipboard data or credentials. Include the Shelf version, macOS version and a reproduction using synthetic content. Do not attach real clipboard databases, screenshots containing private information, tokens or signing material.

## Security boundaries

- Clipboard capture and link enrichment require explicit opt-in. Known sensitive clipboard markers are excluded; arbitrary unmarked secrets cannot be reliably detected.
- Managed data uses user-only permissions. File handling rejects unsafe paths/symlinks at the managed-file boundary. Local user permissions do not protect against another process running as the same user.
- Optional metadata requests use public HTTPS only, validate DNS answers and redirects, bound response sizes, and parse HTML without executing it.
- Shelf has no configured update feed or credential helper. The local build does not check for updates or request GitHub credentials.
- The builder makes an ad-hoc signed local application. It does not claim Developer ID signing, notarization, sandboxing, or Mac App Store approval. See `docs/release-readiness.md`.
- Never commit user history, private screenshots, preferences, signing keys, tokens or test evidence containing personal data. The publication audit and pinned secret scanner run locally and in CI.

Never disable Gatekeeper, change Keychain trust or share signing keys as an installation workaround.

The [troubleshooting guide](https://github.com/baypeanut/shelf/blob/main/docs/troubleshooting.md#report-a-reproducible-problem) describes a safe public bug report. Use the private reporting route above for vulnerability details.
