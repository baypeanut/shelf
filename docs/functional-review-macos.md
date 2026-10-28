# macOS roadmap

These proposals focus on everyday MacBook use. They are not implemented in the current release.

| Priority | Improvement | Acceptance criteria |
| --- | --- | --- |
| 1 | Power-aware indexing | Defer expensive new work under low-power or thermal pressure, reuse valid cached analysis and resume safely when conditions improve. |
| 2 | Full Library backup and restore | Preserve files, folders, tags, edits and identity. Validate archives, collisions and interrupted restores before changing the active Library. |
| 3 | Search-index health and repair | Show pending analysis and model availability, explain missing results and rebuild derived data without changing originals or organization. |
| 4 | Explicit Shortcuts actions | Expose deliberate save/search/export actions with clear input and permission boundaries. Verify platform support before committing to the integration. |
| 5 | Region and language options for OCR | Recognize a selected area, preserve line breaks and allow language/output choices without modifying the original image. |
| 6 | Image export presets | Preview dimensions, format and destination, create non-overwriting output and leave full-resolution originals untouched. |
| 7 | Duplicate and similar-image review | Group likely matches for user review, distinguish exact duplicates from visual similarity and use recoverable removal. |

## Relevant code

`LibraryImageSearch` owns background indexing and cached analysis. `ImageTextCopy` handles OCR transfer. `ImageMarkupRenderer` and `LibraryTransfer` provide image rendering/export boundaries. `LibraryStore` supplies transactional persistence and derived-data invalidation.

Power and thermal behavior should be tested through injected state rather than global system changes. Backup/repair work must support cancellation and failure recovery. New integrations should keep keyboard access and avoid taking focus during background work.
