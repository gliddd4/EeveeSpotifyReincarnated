// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MetadataTagKitTests",
    platforms: [.macOS(.v12)],
    dependencies: [
        .package(path: "../../Sources/EeveeSpotify/Dependencies/MetadataTagKit")
    ],
    targets: [
        .testTarget(
            name: "MetadataTagKitTests",
            dependencies: ["MetadataTagKit"],
            path: "Tests/MetadataTagKitTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
