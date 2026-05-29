// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Important: Use these settings for most targets.
let swiftSettings: [SwiftSetting]? = [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "StockChartsKit",
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "StockChartsKit",
            targets: ["StockChartsKit"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "StockChartsKit",
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitTests",
            dependencies: ["StockChartsKit"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
