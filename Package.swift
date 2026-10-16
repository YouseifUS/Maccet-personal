// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UnifiedUpdater",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "UnifiedUpdater", targets: ["UnifiedUpdater"]),
        .library(name: "UpdaterCore", targets: ["UpdaterCore"])
    ],
    targets: [
        .target(name: "UpdaterCore", resources: [.process("Resources")]),
        .executableTarget(name: "UnifiedUpdater", dependencies: ["UpdaterCore"], resources: [.process("Resources")]),
        // The executable check suite also runs with Command Line Tools alone.
        .executableTarget(name: "UpdaterCoreChecks", dependencies: ["UpdaterCore"], path: "Tests/UpdaterCoreTests")
    ]
)
