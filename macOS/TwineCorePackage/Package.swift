// swift-tools-version: 6.2

import Foundation
import PackageDescription

let artifactName = "TwineCore.xcframework"
let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let artifactURL = packageDirectory.appendingPathComponent(artifactName)

guard FileManager.default.fileExists(atPath: artifactURL.path) else {
    fatalError(
        """
        TwineCore.xcframework is missing. From the repository root, run \
        'make debug' for Debug builds or \
        'make release' for Release builds.
        """
    )
}

let package = Package(
    name: "TwineCorePackage",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "TwineCore", targets: ["TwineCore"])
    ],
    targets: [
        .binaryTarget(name: "TwineCore", path: artifactName)
    ]
)
