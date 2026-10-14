// swift-tools-version: 5.9
import PackageDescription

// CLiteRTLM.xcframework — C API LiteRT-LM v0.17.1 из релиза
// https://github.com/google-ai-edge/LiteRT-LM/releases/tag/v0.17.1
// (CLiteRTLM_mac.xcframework, только arm64). Лицензия Apache 2.0.
let package = Package(
    name: "litert_lm",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .library(name: "litert-lm", targets: ["litert_lm"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .binaryTarget(
            name: "CLiteRTLM",
            path: "CLiteRTLM.xcframework"
        ),
        .target(
            name: "litert_lm",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework"),
                "CLiteRTLM",
            ]
        )
    ]
)
