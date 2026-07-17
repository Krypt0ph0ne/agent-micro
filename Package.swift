// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexPad",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexPad", targets: ["CodexPad"]),
        .executable(name: "CodexPadHIDProbe", targets: ["CodexPadHIDProbe"])
    ],
    targets: [
        .executableTarget(
            name: "CodexPad",
            path: ".",
            exclude: ["References", "Tests", "Tools", "script", "LICENSES", "Examples", "README.md", ".codex", "dist", "Support/ch57x-keyboard-tool"],
            sources: ["App", "Models", "Stores", "Services", "Views", "Support"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "CodexPadHIDProbe",
            path: "Tools/HIDProbe"
        ),
        .testTarget(
            name: "CodexPadTests",
            dependencies: ["CodexPad"],
            path: "Tests"
        )
    ]
)
