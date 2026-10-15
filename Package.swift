// swift-tools-version: 6.0
//
// Cuardach — open-source AR authoring and exploration for iPhone and iPad.
//
// CuardachCore is Foundation-only and builds on macOS, iOS and Linux, so the
// bundle format, behaviour engine and anchor resolver are tested anywhere.
// CuardachAR and CuardachUI compile only where ARKit / RealityKit / SwiftUI
// exist; on other platforms their sources are compiled out with `#if`.
// The iOS app target itself lives in App/ and is generated with XcodeGen.

import PackageDescription

let package = Package(
    name: "Cuardach",
    platforms: [
        .iOS("26.0"),
        .macOS("15.0"),
    ],
    products: [
        .library(name: "CuardachCore", targets: ["CuardachCore"]),
        .library(name: "CuardachAR", targets: ["CuardachAR"]),
        .library(name: "CuardachUI", targets: ["CuardachUI"]),
        .executable(name: "cuardach", targets: ["cuardach"]),
    ],
    targets: [
        .target(name: "CuardachCore"),
        .target(name: "CuardachAR", dependencies: ["CuardachCore"]),
        .target(name: "CuardachUI", dependencies: ["CuardachCore", "CuardachAR"]),
        .executableTarget(name: "cuardach", dependencies: ["CuardachCore"]),
        .testTarget(name: "CuardachCoreTests", dependencies: ["CuardachCore"]),
    ],
    swiftLanguageModes: [.v6]
)
