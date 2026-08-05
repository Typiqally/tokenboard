// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tokenboard",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TokenboardCore", targets: ["TokenboardCore"]),
        .executable(name: "TokenboardApp", targets: ["TokenboardApp"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "TokenboardCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "TokenboardApp", dependencies: ["TokenboardCore"]),
        .testTarget(name: "TokenboardCoreTests", dependencies: ["TokenboardCore"])
    ]
)
