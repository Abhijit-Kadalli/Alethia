// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Alethia",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AlethiaCore", targets: ["AlethiaCore"]),
        .library(name: "AlethiaAudio", targets: ["AlethiaAudio"]),
        .library(name: "AlethiaASR", targets: ["AlethiaASR"]),
        .library(name: "AlethiaDiarization", targets: ["AlethiaDiarization"]),
        .library(name: "AlethiaKnowledge", targets: ["AlethiaKnowledge"]),
        .library(name: "AlethiaDictation", targets: ["AlethiaDictation"]),
        .executable(name: "Alethia", targets: ["AlethiaApp"])
    ],
    targets: [
        .target(
            name: "AlethiaCore",
            path: "Packages/AlethiaCore/Sources/AlethiaCore"
        ),
        .target(
            name: "AlethiaKnowledge",
            dependencies: ["AlethiaCore"],
            path: "Packages/AlethiaKnowledge/Sources/AlethiaKnowledge"
        ),
        .target(
            name: "AlethiaAudio",
            dependencies: ["AlethiaCore"],
            path: "Packages/AlethiaAudio/Sources/AlethiaAudio"
        ),
        .target(
            name: "AlethiaASR",
            dependencies: ["AlethiaCore"],
            path: "Packages/AlethiaASR/Sources/AlethiaASR"
        ),
        .target(
            name: "AlethiaDiarization",
            dependencies: ["AlethiaCore", "AlethiaKnowledge"],
            path: "Packages/AlethiaDiarization/Sources/AlethiaDiarization"
        ),
        .target(
            name: "AlethiaDictation",
            dependencies: ["AlethiaCore", "AlethiaASR", "AlethiaKnowledge"],
            path: "Packages/AlethiaDictation/Sources/AlethiaDictation"
        ),
        .executableTarget(
            name: "AlethiaApp",
            dependencies: [
                "AlethiaCore",
                "AlethiaAudio",
                "AlethiaASR",
                "AlethiaDiarization",
                "AlethiaKnowledge",
                "AlethiaDictation"
            ],
            path: "Apps/Alethia/Sources"
        )
    ]
)
