// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MercurySpike",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "OpenRouterAPI", targets: ["OpenRouterAPI"]),
        .library(name: "EvalHarness", targets: ["EvalHarness"]),
        .executable(name: "mercury-spike", targets: ["MercurySpike"]),
        .executable(name: "eval-runner", targets: ["EvalRunner"]),
    ],
    targets: [
        .target(name: "OpenRouterAPI"),
        .target(name: "EvalHarness", dependencies: ["OpenRouterAPI"]),
        .executableTarget(name: "MercurySpike", dependencies: ["OpenRouterAPI"]),
        .executableTarget(name: "EvalRunner", dependencies: ["EvalHarness", "OpenRouterAPI"]),
        .testTarget(name: "OpenRouterAPITests", dependencies: ["OpenRouterAPI"]),
        .testTarget(name: "EvalHarnessTests", dependencies: ["EvalHarness"]),
    ]
)
