// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [.macOS(.v14)],
    targets: [
        // Resources holds the translations. scripts/build-community.sh copies them
        // into the app, so SwiftPM leaves them alone.
        // Shelf builds with system frameworks only and has no in-app updater.
        .executableTarget(name: "Shelf", path: "Sources/Shelf", exclude: ["Resources"]),
        .testTarget(name: "ShelfTests", dependencies: ["Shelf"]),
        .testTarget(name: "ImageHistoryTests", dependencies: ["Shelf"], path: "Tests/ImageHistoryTests")
    ]
)
