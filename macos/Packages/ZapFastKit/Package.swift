// swift-tools-version: 6.2
//
// ZapFastKit: every module of the macOS app except its thin app target.
//
// Dependency direction (arrows point at what a module imports):
//
//   ZapFastShell ─┬─▶ FeatureOnboarding ──┐
//                 ├─▶ FeatureChats ───────┤
//                 ├─▶ FeatureConversation ┼─▶ ZapFastSharedUI ─┬─▶ ZapFastDesign
//                 ├─▶ FeatureSettings ────┤                    └─▶ ZapFastCore ─▶ ZapFastBridge ─▶ ZapFastBridgeFFI
//                 ├─▶ FeatureLock ────────┤
//                 └─▶ FeatureCalls ───────┘
//
// ZapFastDesign knows nothing about WhatsApp; ZapFastSharedUI adapts bridge
// types to it for every feature. Features never import each other; the
// shell composes them.

import PackageDescription

/// Interface modules run on the main actor unless they say otherwise.
let uiSettings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "ZapFastKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ZapFastShell", targets: ["ZapFastShell"]),
    ],
    dependencies: [
        // libphonenumber's formats, for numbers written as WhatsApp writes them.
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit", from: "5.0.11"),
        // Plays Lottie stickers (WhatsApp's .was files hold a Lottie animation).
        .package(url: "https://github.com/airbnb/lottie-ios", from: "4.6.1"),
    ],
    targets: [
        // Rust static library and C header, built by Scripts/build-bridge.sh.
        .binaryTarget(
            name: "ZapFastBridgeFFI",
            path: "Artifacts/ZapFastBridgeFFI.xcframework"
        ),

        // UniFFI-generated Swift over the FFI, plus small conformances.
        .target(
            name: "ZapFastBridge",
            dependencies: ["ZapFastBridgeFFI"],
            // Exactly what `cargo rustc -- --print native-static-libs` reports
            // for the bridge (see Scripts/print-link-libs.sh). Refresh it when
            // an upstream bump fails to link.
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("Foundation"),
                .linkedFramework("OpenGL"),
                .linkedFramework("Security"),
                .linkedLibrary("c++"),
                .linkedLibrary("iconv"),
                .linkedLibrary("objc"),
            ]
        ),

        // State, intents, and the backend connection. No views.
        .target(
            name: "ZapFastCore",
            dependencies: ["ZapFastBridge", .product(name: "PhoneNumberKit", package: "PhoneNumberKit")],
            swiftSettings: uiSettings
        ),

        // Colours, metrics, and shared views. Knows nothing about WhatsApp.
        .target(
            name: "ZapFastDesign",
            resources: [.process("Resources")],
            swiftSettings: uiSettings
        ),

        // Views shared by features that need both the model and the kit.
        .target(
            name: "ZapFastSharedUI",
            dependencies: ["ZapFastCore", "ZapFastDesign"],
            swiftSettings: uiSettings
        ),

        .target(
            name: "FeatureOnboarding",
            dependencies: ["ZapFastCore", "ZapFastDesign", "ZapFastSharedUI"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "FeatureChats",
            dependencies: ["ZapFastCore", "ZapFastDesign", "ZapFastSharedUI"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "FeatureConversation",
            dependencies: [
                "ZapFastCore", "ZapFastDesign", "ZapFastSharedUI",
                .product(name: "Lottie", package: "lottie-ios"),
            ],
            // The search bar's words, one table per language.
            resources: [.process("Resources")],
            swiftSettings: uiSettings
        ),
        .target(
            name: "FeatureSettings",
            dependencies: ["ZapFastCore", "ZapFastDesign", "ZapFastSharedUI"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "FeatureCalls",
            dependencies: ["ZapFastCore", "ZapFastDesign", "ZapFastSharedUI"],
            swiftSettings: uiSettings
        ),
        .target(
            name: "FeatureLock",
            dependencies: ["ZapFastCore", "ZapFastDesign", "ZapFastSharedUI"],
            swiftSettings: uiSettings
        ),

        // Scenes, window, split, menus: composes the features.
        .target(
            name: "ZapFastShell",
            dependencies: [
                "ZapFastCore",
                "ZapFastDesign",
                "ZapFastSharedUI",
                "FeatureOnboarding",
                "FeatureChats",
                "FeatureConversation",
                "FeatureSettings",
                "FeatureLock",
                "FeatureCalls",
            ],
            swiftSettings: uiSettings
        ),

        .testTarget(
            name: "ZapFastCoreTests",
            dependencies: ["ZapFastCore", "ZapFastDesign"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "FeatureConversationTests",
            dependencies: ["FeatureConversation", "ZapFastCore"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "FeatureChatsTests",
            dependencies: ["FeatureChats", "ZapFastCore"],
            swiftSettings: uiSettings
        ),
        .testTarget(
            name: "FeatureCallsTests",
            dependencies: ["FeatureCalls", "ZapFastCore"],
            swiftSettings: uiSettings
        ),
    ]
)
