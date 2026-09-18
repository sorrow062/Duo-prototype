// swift-tools-version:5.5
import PackageDescription

// Binary package manifest from Sparkle 2.10.0, pinned to the official
// release archive and its published checksum to avoid cloning full history.
let version = "2.10.0"
let url = "https://github.com/sparkle-project/Sparkle/releases/download/\(version)/Sparkle-for-Swift-Package-Manager.zip"

let package = Package(
    name: "Sparkle",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "Sparkle", targets: ["Sparkle"])
    ],
    targets: [
        .binaryTarget(
            name: "Sparkle",
            url: url,
            checksum: "17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
        )
    ]
)
