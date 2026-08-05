// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetadataTagKit",
    platforms: [.macOS(.v12)],
    products: [
        .library(name: "MetadataTagKit", targets: ["MetadataTagKit"])
    ],
    targets: [
        .target(name: "MetadataTagKit", path: "Sources/MetadataTagKit")
    ]
)
