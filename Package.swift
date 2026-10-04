// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Nook",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Nook", targets: ["Nook"]),
        .executable(name: "NookFixture", targets: ["NookFixture"]),
        .executable(name: "NookAudit", targets: ["NookAudit"])
    ],
    targets: [
        .target(name: "MenuBarCore"),
        .executableTarget(name: "Nook", dependencies: ["MenuBarCore"]),
        .executableTarget(name: "NookFixture", dependencies: ["MenuBarCore"]),
        .executableTarget(name: "NookAudit", dependencies: ["MenuBarCore"]),
        .testTarget(name: "MenuBarCoreTests", dependencies: ["MenuBarCore"])
    ],
    swiftLanguageModes: [.v6]
)
