// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "apfel-server-kit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ApfelServerKit", targets: ["ApfelServerKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.6"),
    ],
    targets: [
        .target(
            name: "ApfelServerKit",
            dependencies: [],
            path: "Sources/ApfelServerKit"
        ),
        .executableTarget(
            name: "apfel-server-kit-tests",
            dependencies: ["ApfelServerKit"],
            path: "Tests/ApfelServerKitTests"
        ),
    ]
)
