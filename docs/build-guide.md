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
