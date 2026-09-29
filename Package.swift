// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SSHRemote",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // xtool wants exactly one library product: the app itself.
        .library(name: "SSHRemote", targets: ["SSHRemote"]),
    ],
    dependencies: [
        // Apple's own SSH implementation — deliberately not Citadel, whose
        // 0.12.1 moved its SSH core onto an unvetted third-party fork.
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.0"),
        // Pinned to the last releases that don't use Swift's `package` access
        // level: xtool's SwiftBuild never passes -package-name, so newer
        // swift-nio (2.84+) and swift-collections (1.3+) fail to compile.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.83.0"),
        .package(url: "https://github.com/apple/swift-collections.git", exact: "1.2.1"),
    ],
    targets: [
        .target(
            name: "SSHRemote",
            dependencies: [
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ]
        ),
    ],
    // NIO channel handlers predate strict concurrency checking; Swift 5 mode
    // keeps the SSH glue readable instead of burying it in @Sendable noise.
    swiftLanguageModes: [.v5]
)
