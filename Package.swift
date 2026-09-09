// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Orrery",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "Remote/OrreryRemoteProtocol"),
    ],
    targets: [
        .executableTarget(
            name: "Orrery",
            dependencies: [.product(name: "OrreryRemoteProtocol", package: "OrreryRemoteProtocol"), .product(name: "OrreryRemoteClient", package: "OrreryRemoteProtocol")],
            path: "Sources/Orrery",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "OrreryTests",
            path: "Tests/OrreryTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
