// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DuoPrototype",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "DuoPrototype", targets: ["DuoPrototype"])
    ],
    dependencies: [
        .package(path: "Vendor/Sparkle")
    ],
    targets: [
        .executableTarget(
            name: "DuoPrototype",
            dependencies: [
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/DuoPrototype"
        )
    ]
)
