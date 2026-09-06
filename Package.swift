// swift-tools-version: 5.10
import PackageDescription

// Platform-independent targets build and test everywhere (Linux CI gives fast feedback on
// the text pipeline and storage). Audio, speech, dictation and the app itself are macOS-only.

var products: [Product] = [
    .library(name: "AlethiaCore", targets: ["AlethiaCore"]),
    .library(name: "AlethiaText", targets: ["AlethiaText"]),
    .library(name: "AlethiaKnowledge", targets: ["AlethiaKnowledge"]),
    .library(name: "AlethiaAudio", targets: ["AlethiaAudio"]),
]

var dependencies: [Package.Dependency] = []

var targets: [Target] = [
    .target(
        name: "AlethiaCore",
        path: "Sources/AlethiaCore"
    ),
    .systemLibrary(
        name: "CSQLite",
        path: "Sources/CSQLite",
        providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite"])]
    ),
    .target(
        name: "AlethiaText",
        dependencies: ["AlethiaCore"],
        path: "Sources/AlethiaText"
    ),
    .target(
        name: "AlethiaKnowledge",
        dependencies: ["AlethiaCore", "CSQLite"],
        path: "Sources/AlethiaKnowledge"
    ),
    // Mixer / WAV writer are pure Swift and tested on Linux; capture code is `#if os(macOS)`.
    .target(
        name: "AlethiaAudio",
        dependencies: ["AlethiaCore"],
        path: "Sources/AlethiaAudio",
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
            .linkedFramework("CoreAudio", .when(platforms: [.macOS])),
            .linkedFramework("ScreenCaptureKit", .when(platforms: [.macOS])),
        ]
    ),
    .testTarget(
        name: "AlethiaAudioTests",
        dependencies: ["AlethiaAudio", "AlethiaCore"],
        path: "Tests/AlethiaAudioTests"
    ),
    .testTarget(
        name: "AlethiaCoreTests",
        dependencies: ["AlethiaCore"],
        path: "Tests/AlethiaCoreTests"
    ),
    .testTarget(
        name: "AlethiaTextTests",
        dependencies: ["AlethiaText", "AlethiaCore"],
        path: "Tests/AlethiaTextTests"
    ),
    .testTarget(
        name: "AlethiaKnowledgeTests",
        dependencies: ["AlethiaKnowledge", "AlethiaCore"],
        path: "Tests/AlethiaKnowledgeTests"
    ),
]

#if os(macOS)
products += [
    .library(name: "AlethiaSpeech", targets: ["AlethiaSpeech"]),
    .library(name: "AlethiaDictation", targets: ["AlethiaDictation"]),
    .library(name: "AlethiaMeetings", targets: ["AlethiaMeetings"]),
    .executable(name: "Alethia", targets: ["AlethiaApp"]),
]

dependencies += [
    // Pinned: 0.15.6+ statically links a ~30 MB text-normalization library, which would
    // blow the 10 MB app budget. 0.15.5 is pure Swift + CoreML.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
]

targets += [
    .target(
        name: "AlethiaSpeech",
        dependencies: [
            "AlethiaCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ],
        path: "Sources/AlethiaSpeech"
    ),
    .target(
        name: "AlethiaDictation",
        dependencies: ["AlethiaCore", "AlethiaText", "AlethiaSpeech", "AlethiaKnowledge", "AlethiaAudio"],
        path: "Sources/AlethiaDictation"
    ),
    .target(
        name: "AlethiaMeetings",
        dependencies: ["AlethiaCore", "AlethiaText", "AlethiaSpeech", "AlethiaKnowledge", "AlethiaAudio"],
        path: "Sources/AlethiaMeetings",
        linkerSettings: [
            .linkedFramework("EventKit"),
        ]
    ),
    .executableTarget(
        name: "AlethiaApp",
        dependencies: [
            "AlethiaCore",
            "AlethiaText",
            "AlethiaKnowledge",
            "AlethiaAudio",
            "AlethiaSpeech",
            "AlethiaDictation",
            "AlethiaMeetings",
        ],
        path: "Sources/AlethiaApp",
        linkerSettings: [
            .linkedFramework("UserNotifications"),
            .linkedFramework("ServiceManagement"),
        ]
    ),
    .testTarget(
        name: "AlethiaMeetingsTests",
        dependencies: ["AlethiaMeetings", "AlethiaCore"],
        path: "Tests/AlethiaMeetingsTests"
    ),
]
#endif

let package = Package(
    name: "Alethia",
    platforms: [
        .macOS(.v14),
    ],
    products: products,
    dependencies: dependencies,
    targets: targets
)
