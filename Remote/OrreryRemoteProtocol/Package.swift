// swift-tools-version: 6.0
import PackageDescription

// The wire protocol shared by Orrery (the Mac) and Orrery Remote (the iPhone): pairing offers,
// the key agreement, sealed frames and the message vocabulary. Foundation and CryptoKit only.
let package = Package(
    name: "OrreryRemoteProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OrreryRemoteProtocol", targets: ["OrreryRemoteProtocol"]),
        .library(name: "OrreryRemoteClient", targets: ["OrreryRemoteClient"]),
    ],
    targets: [
        .target(name: "OrreryRemoteClient", dependencies: ["OrreryRemoteProtocol"], path: "Sources/OrreryRemoteClient", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "OrreryRemoteProtocol", path: "Sources/OrreryRemoteProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
