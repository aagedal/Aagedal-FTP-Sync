// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "BigInt",
    platforms: [
        .macOS(.v10_13),
        .iOS(.v12),
        .tvOS(.v12),
        // Xcode 27 no longer supports watchOS deployment targets below 9.
        .watchOS(.v9),
        .macCatalyst(.v13),
        .visionOS(.v1),
    ],
    products: [
        .library(name: "BigInt", targets: ["BigInt"]),
    ],
    targets: [
        .target(
            name: "BigInt",
            path: "Sources",
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        ),
    ]
)
