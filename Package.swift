// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TranscriptDock",
    platforms: [.macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8), .visionOS(.v1)],
    products: [
        .library(name: "TranscriptDock", targets: ["TranscriptDock"]),
    ],
    targets: [
        .target(name: "TranscriptDock"),
        // Contract checks against the loopback fixture in .ci. Not part of the library product.
        .executableTarget(name: "ClientCheck", dependencies: ["TranscriptDock"]),
        .testTarget(name: "TranscriptDockTests", dependencies: ["TranscriptDock"]),
    ]
)
