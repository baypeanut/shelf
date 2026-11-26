// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Shelf",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        // Resources holds the translations. scripts/build-community.sh copies them
        // into the app, so SwiftPM leaves them alone.
        .executableTarget(name: "Shelf", dependencies: [.product(name: "Sparkle", package: "Sparkle")], path: "Sources/Shelf", exclude: ["Resources"]),
        .testTarget(name: "ShelfTests", dependencies: ["Shelf"]),
        .testTarget(name: "ImageHistoryTests", dependencies: ["Shelf"], path: "Tests/ImageHistoryTests")
    ]
)
