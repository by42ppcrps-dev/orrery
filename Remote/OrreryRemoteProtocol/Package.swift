// swift-tools-version: 6.0
import PackageDescription

// The wire protocol shared by Orrery (the Mac) and Orrery Remote (the iPhone): pairing offers,
// the key agreement, sealed frames and the message vocabulary. Foundation and CryptoKit only.
let package = Package(
    name: "OrreryRemoteProtocol",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "OrreryRemoteProtocol", targets: ["OrreryRemoteProtocol"]),
    ],
    targets: [
        .target(name: "OrreryRemoteProtocol", path: "Sources/OrreryRemoteProtocol", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
