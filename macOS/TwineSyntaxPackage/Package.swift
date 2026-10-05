// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "TwineSyntaxPackage",
    platforms: [.macOS(.v26)],
    products: [.library(name: "TwineSyntax", targets: ["TwineSyntax"])],
    dependencies: [
        // Grammar releases use this original URL, which redirects to tree-sitter/swift-tree-sitter.
        // Keep one SwiftPM identity for the wrapper throughout the dependency graph.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.10.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter", exact: "0.25.10"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.1-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", exact: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", exact: "0.23.6"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-toml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.23.3"),
    ],
    targets: [
        .target(
            name: "TwineSyntax",
            dependencies: [
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterTOML", package: "tree-sitter-toml"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
            ],
            resources: [.copy("Resources/Queries"), .copy("Resources/Licenses")]
        )
    ],
    swiftLanguageModes: [.v6]
)
