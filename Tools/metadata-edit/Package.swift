// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "metadata-edit",
    platforms: [
        .macOS(.v12)
    ],
    dependencies: [
        .package(path: "../../Sources/EeveeSpotify/Dependencies/MetadataTagKit")
    ],
    targets: [
        .executableTarget(
            name: "metadata-edit",
            dependencies: ["MetadataTagKit"],
            path: "Sources/metadata-edit"
        )
    ]
)
