// swift-tools-version: 6.2

import Foundation
import PackageDescription

let artifactName = "TwineBridge.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactURL = packageDirectory.appendingPathComponent(artifactName)

guard FileManager.default.fileExists(atPath: artifactURL.path) else {
    fatalError(
        """
        TwineBridge.xcframework is missing. From the repository root, run \
        'scripts/build-bridge.sh debug' for Debug builds or \
        'scripts/build-bridge.sh release' for Release builds.
        """
    )
}

let package = Package(
    name: "TwineBridgePackage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TwineBridge", targets: ["TwineBridge"]),
    ],
    targets: [
        .binaryTarget(name: "TwineBridge", path: artifactName),
    ]
)
