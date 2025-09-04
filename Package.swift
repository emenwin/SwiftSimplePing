// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "SwiftSimplePing",
    platforms: [.iOS(.v12), .tvOS(.v12), .macOS(.v10_13)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "SimplePing",
            targets: ["SimplePing"]),
        .library(
            name: "SimpleTraceroute",
            targets: ["SimpleTraceroute"]),
        .library(
            name: "SwiftSimplePing",
            targets: ["SwiftSimplePing"]),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.

        .target(
            name: "SimplePing",
            dependencies: [],
            path: "SimplePing",
            publicHeadersPath: "Public"
        ),
        .target(
            name: "SimpleTraceroute",
            dependencies: ["SimplePing"],
            path: "SimpleTraceroute",
            publicHeadersPath: "Public"
        ),
        .target(
            name: "SwiftSimplePing",
            dependencies: ["SimplePing", "SimpleTraceroute"],
            path: "SwiftSimplePing"
        ),

    ]
)
