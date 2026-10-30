# Dependencies

Shelf builds with system frameworks: AppKit, SwiftUI, Vision, Core ML, Core Graphics, AVFoundation and SQLite. The default build does not download model weights or bundle a third-party updater.

## Optional visual search

The optional search build uses MobileCLIP-S2 model assets and tokenizer resources. Downloads are pinned to specific revisions and model weights are checked against SHA-256 digests by `scripts/prepare-search-models.py`.

Model assets are stored in the ignored `local/models/MobileCLIP` directory and bundled in `Contents/Resources/CLIP` only when requested. Their component terms and acknowledgements are included in that bundle as `LICENSE-MobileCLIP-S2`, `LICENSE-Apple-code` and `ACKNOWLEDGEMENTS-MobileCLIP`. Preserve those files when distributing a build containing the optional assets.

The model assets are not committed to this repository. Their terms apply separately from the application source. The default build uses local Vision text recognition without downloading model weights.

Build and verification commands are in [Building Shelf](https://github.com/baypeanut/shelf/blob/main/docs/build-guide.md#include-visual-search). Keep model downloads, generated bundles and their local caches out of source commits.
