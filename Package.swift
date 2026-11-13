// swift-tools-version: 6.2
// Blend: native macOS remix console. C++ audio engine, Swift kit, SwiftUI app, CLI test tool.
import PackageDescription

let package = Package(
    name: "Blend",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "BlendEngine",
            path: "Sources/BlendEngine",
            exclude: ["vendor/LICENSE-signalsmith-stretch.txt", "vendor/LICENSE-signalsmith-linear.txt"],
            cxxSettings: [.headerSearchPath("vendor"), .define("SIGNALSMITH_USE_ACCELERATE")],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(name: "BlendKit", dependencies: ["BlendEngine"], path: "Sources/BlendKit"),
        .executableTarget(name: "Blend", dependencies: ["BlendKit"], path: "Sources/Blend"),
        .executableTarget(name: "blendtool", dependencies: ["BlendKit"], path: "Sources/blendtool")
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
