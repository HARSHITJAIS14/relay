// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Companion",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Companion", targets: ["Companion"]),
        .library(name: "CompanionCore", targets: ["CompanionCore"])
    ],
    targets: [
        .target(name: "CompanionCore"),
        .target(name: "CompanionTransport", dependencies: ["CompanionCore"]),
        .executableTarget(name: "Companion", dependencies: ["CompanionCore", "CompanionTransport"]),
        .testTarget(name: "CompanionCoreTests", dependencies: ["CompanionCore"]),
        .testTarget(name: "CompanionTransportTests", dependencies: ["CompanionTransport"])
    ]
)
