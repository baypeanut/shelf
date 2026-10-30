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
