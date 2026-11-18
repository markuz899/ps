// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PS",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PSCore", resources: [.copy("Resources/Themes")]),
        .executableTarget(name: "PS", dependencies: ["PSCore"]),
        .testTarget(name: "PSCoreTests", dependencies: ["PSCore"]),
    ]
)
