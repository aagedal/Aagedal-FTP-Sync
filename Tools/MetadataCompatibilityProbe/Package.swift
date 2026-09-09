// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetadataCompatibilityProbe",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/aagedal/SwiftMediaMetadata.git", exact: "2.0.0")],
    targets: [.executableTarget(name: "MetadataCompatibilityProbe", dependencies: [
        .product(name: "SwiftMediaMetadata", package: "SwiftMediaMetadata")
    ])]
)
