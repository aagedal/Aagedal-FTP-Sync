// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MetadataProcessing",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MetadataTemplates", targets: ["MetadataTemplates"])],
    targets: [
        .target(name: "MetadataTemplates"),
        .testTarget(name: "MetadataTemplatesTests", dependencies: ["MetadataTemplates"]),
    ]
)
