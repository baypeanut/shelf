# Security review

The review covers clipboard admission, local persistence, file handling, optional link previews, direct paste and packaging. Native regression tests exercise these boundaries with synthetic content. This is an engineering review, not an external penetration test or distribution certification.

## Capture and storage

- Clipboard payloads are read only after explicit source opt-in. Known concealed, confidential, transient and password-manager markers are excluded.
- Finder file copies do not become text or image captures. Change-count checks reject a pasteboard replaced during a read. Enabling capture skips its existing contents.
- Text input is limited to 1 MiB. Image input is limited to 32 MiB and 40 million pixels before conversion.
- Managed directories use mode 0700 and files use mode 0600. Descriptor-based writes reject symbolic links, pin the intended directory and clean up incomplete captures.
- SQLite uses bound values, foreign keys, integrity checks and transactions. Backups include committed WAL data. Corrupt data blocks migration rather than becoming an empty Library.
- History cleanup preserves pinned and organized items and uses recoverable Trash for owned files. Exports do not overwrite existing files or modify originals.

## Network and updates

Link previews are a separate opt-in. Requests use public HTTPS destinations, validate DNS answers and redirects, reject credential-bearing URLs and private/reserved addresses, and bound response sizes and timeouts. HTML is parsed as data without running scripts. No browser session, cookies or authorization headers are reused.

The local app has no configured update feed, credential helper or automatic update traffic. A future update channel needs an explicit configuration and signing design.

## Known boundaries

Local files are protected by account permissions, not application encryption. Another process running as the same user can access the history. Clipboard markers are cooperative, so unmarked secrets cannot always be identified. A permitted link-preview request reveals its destination and the user's IP address to the website.

Release qualification still needs distribution signing, notarization or App Store sandbox/entitlement review, actual external-app Accessibility paste, clean-account consent testing and supported-platform coverage. See [Security](../SECURITY.md), [Privacy](../PRIVACY.md) and [Release readiness](release-readiness.md).
