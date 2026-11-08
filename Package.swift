// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FileConverter",
    platforms: [.macOS(.v14)],
    products: [
        // The Xcode app project depends on this library.
        .library(name: "ConverterCore", targets: ["ConverterCore"]),
    ],
    targets: [
        // Everything that does the real work: detection, routing, tool calls, Ollama.
        // No UI code here, so it can be tested from the command line.
        .target(name: "ConverterCore"),

        // The SwiftUI macOS app.
        .executableTarget(
            name: "FileConverter",
            dependencies: ["ConverterCore"]
        ),

        .testTarget(
            name: "ConverterCoreTests",
            dependencies: ["ConverterCore"]
        ),
    ]
)
