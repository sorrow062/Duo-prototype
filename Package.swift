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
    targets: [
        .executableTarget(
            name: "DuoPrototype",
            path: "Sources/DuoPrototype"
        )
    ]
)
