// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fileto",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FiletoCore", targets: ["FiletoCore"]),
        .executable(name: "Fileto", targets: ["FiletoApp"]),
        .executable(name: "fileto-probe", targets: ["FiletoProbe"])
    ],
    targets: [
        .target(name: "FiletoCore"),
        .executableTarget(name: "FiletoApp", dependencies: ["FiletoCore"],
                          exclude: ["Resources/Assets.xcassets"],
                          resources: [.copy("Resources/AppIcon.icns")]),
        .executableTarget(name: "FiletoProbe", dependencies: ["FiletoCore"]),
        .testTarget(name: "FiletoCoreTests", dependencies: ["FiletoCore"]),
        .testTarget(name: "FiletoAppTests", dependencies: ["FiletoApp", "FiletoCore"])
    ]
)
