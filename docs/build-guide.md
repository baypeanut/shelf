# Building Shelf

Run build commands from the repository root on macOS 14 or later. The source package is macOS-only and the builder targets the architecture of the Mac running it.

## Check the tools

Install Xcode with the macOS SDK and Python 3. Before diagnosing a build, record the active toolchain:

```sh
xcode-select -p
swift --version
xcrun --show-sdk-path
python3 --version
```

## Build the app

```sh
bash scripts/build-community.sh release
```

The script builds the executable, resources, translations, icon and privacy manifest, then signs and verifies the resulting `build/Shelf.app`. It performs an isolated startup check and leaves the app ready to open.

## Use a debug build

```sh
bash scripts/build-community.sh debug
```

The output path is also `build/Shelf.app`, so this replaces the previous packaged build. Keep a separate copy if you need to compare debug and release applications.

## Include visual search

```sh
SHELF_BUNDLE_MODELS=1 bash scripts/build-community.sh release
```

The model preparation step downloads pinned assets into ignored local storage. Models and their component notices are included only for this optional build. The default build still includes local Vision text recognition.

## Handle model downloads

The model preparer checks pinned weight digests before use. If a download fails verification, inspect the error and the network path before retrying. Keep the pinned values and component notices intact. See [Dependencies](../DEPENDENCIES.md).

## Verify the bundle

```sh
python3 scripts/check-release-version.py --app build/Shelf.app
python3 scripts/verify-bundle.py build/Shelf.app
codesign --verify --deep --strict build/Shelf.app
```

These checks cover version, identity, resources, runtime paths, signature integrity and isolated startup. They can be rerun after copying a bundle.

## Open or keep it

```sh
open build/Shelf.app
```

To keep the app installed, quit the running copy and move the verified bundle to your Applications folder. Use one installed copy consistently when checking launch-at-login or macOS permissions.

## Change a release version

`release-version.json` holds the version and build number used by packaging. The version checker expects a stable three-part version and a positive integer bundle build. Run its tests and validate the built app after changing either value.
