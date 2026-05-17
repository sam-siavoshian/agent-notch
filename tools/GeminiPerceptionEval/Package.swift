// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GeminiPerceptionEval",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GeminiPerceptionEval", targets: ["GeminiPerceptionEval"]),
        .executable(name: "gemini-perception-eval", targets: ["gemini-perception-eval-cli"]),
    ],
    targets: [
        .target(
            name: "GeminiPerceptionEval",
            path: "Sources/GeminiPerceptionEval"
        ),
        .executableTarget(
            name: "gemini-perception-eval-cli",
            dependencies: ["GeminiPerceptionEval"],
            path: "Sources/gemini-perception-eval-cli"
        ),
    ]
)
