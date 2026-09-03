// swift-tools-version:5.10
import PackageDescription

// Usage — one menu-bar panel for every metered AI source on this Mac: the
// subscriptions (Claude Code, Codex, Antigravity) and the pay-as-you-go API
// keys (DeepSeek, Moonshot), every one of them drawn on the same axis.
//
// Two targets, the same split every app in this family uses. UsageBarCore is
// pure: the meter model, the per-provider response parsers, the credential
// readers, the HTTP call, and the balance sample store, with no AppKit and no
// window, so all of it is testable against captured payloads. UsageBar is the
// app, and holds the view layer and the polling.
let package = Package(
    name: "UsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "UsageBarCore", targets: ["UsageBarCore"]),
        .executable(name: "usage-bar", targets: ["UsageBar"]),
    ],
    targets: [
        .target(name: "UsageBarCore"),
        .executableTarget(name: "UsageBar", dependencies: ["UsageBarCore"]),
        .testTarget(
            name: "UsageBarCoreTests",
            dependencies: ["UsageBarCore"],
            // Payloads in the shape each endpoint answers with. The parsers
            // are tested against those, not against a shape remembered while
            // writing them.
            resources: [.copy("Fixtures")]
        ),
    ]
)
