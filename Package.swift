// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HLSCachingServer",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "HLSCachingServer",
            targets: ["HLSCachingServer"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/apple/swift-nio",
            from: "2.0.0"
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "HLSCachingServer",
            dependencies: [
                .product(
                    name: "NIO",
                    package: "swift-nio"
                )
            ]
        ),
        .testTarget(
            name: "HLSCachingServerTests",
            dependencies: ["HLSCachingServer"]),
    ]
)
