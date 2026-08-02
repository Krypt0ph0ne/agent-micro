// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentMicro",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AgentMicro", targets: ["AgentMicro"]),
        .executable(name: "AgentMicroHIDProbe", targets: ["AgentMicroHIDProbe"])
    ],
    targets: [
        .executableTarget(
            name: "AgentMicro",
            path: ".",
            exclude: [
                "References", "Tests", "Tools", "script", "LICENSES", "Examples",
                "README.md", "LICENSE", "THIRD_PARTY_NOTICES.md", "CONTRIBUTING.md",
                "CODE_OF_CONDUCT.md", "SECURITY.md", "PRIVACY.md", "TRADEMARKS.md",
                "ASSETS.md", "DEVELOPER_PREVIEW.md",
                ".github", ".codex", "dist", "DesignQA", "design-qa.md",
                "Support/ch57x-keyboard-tool"
            ],
            sources: ["App", "Models", "Stores", "Services", "Views", "Support"],
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "AgentMicroHIDProbe",
            path: "Tools/HIDProbe"
        ),
        .testTarget(
            name: "AgentMicroTests",
            dependencies: ["AgentMicro"],
            path: "Tests"
        )
    ]
)
