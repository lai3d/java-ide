// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "JavaIDE",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "JavaIDE", targets: ["JavaIDE"]),
        .library(name: "JavaIDECore", targets: ["JavaIDECore"]),
    ],
    targets: [
        // UI-independent pieces: LSP client, Java highlighter, text/position math, file tree.
        .target(name: "JavaIDECore"),
        // SwiftUI/AppKit application shell.
        .executableTarget(name: "JavaIDE", dependencies: ["JavaIDECore"]),
        .testTarget(name: "JavaIDECoreTests", dependencies: ["JavaIDECore"]),
    ]
)
