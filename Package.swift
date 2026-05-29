// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Core library types are nonisolated Sendable value types, so they must not
// adopt MainActor default isolation. Strict concurrency comes from the v6
// language mode declared below; the upcoming-feature flag is applied
// consistently to every first-party target as a belt-and-suspenders measure
// per PRD §1.
let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("StrictConcurrency")
]

let package = Package(
    name: "StockChartsKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // One library product per provider plus core, market data, and testing,
        // so the host app can pick which ones to link (PRD §2).
        .library(
            name: "StockChartsKit",
            targets: ["StockChartsKit"]
        ),
        .library(
            name: "StockChartsKitTesting",
            targets: ["StockChartsKitTesting"]
        ),
        .library(
            name: "StockChartsKitMarketData",
            targets: ["StockChartsKitMarketData"]
        ),
        .library(
            name: "StockChartsKitCSV",
            targets: ["StockChartsKitCSV"]
        ),
        .library(
            name: "StockChartsKitCoinbase",
            targets: ["StockChartsKitCoinbase"]
        ),
        .library(
            name: "StockChartsKitETrade",
            targets: ["StockChartsKitETrade"]
        ),
        .library(
            name: "StockChartsKitSchwab",
            targets: ["StockChartsKitSchwab"]
        ),
        .library(
            name: "StockChartsKitSnapTrade",
            targets: ["StockChartsKitSnapTrade"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.0.0"),
        .package(url: "https://github.com/apple/swift-collections.git", .upToNextMajor(from: "1.1.0")),
    ],
    targets: [
        // MARK: Core

        .target(
            name: "StockChartsKit",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Collections", package: "swift-collections"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Test support

        .target(
            name: "StockChartsKitTesting",
            dependencies: ["StockChartsKit"],
            swiftSettings: swiftSettings
        ),

        // MARK: Market data

        .target(
            name: "StockChartsKitMarketData",
            dependencies: ["StockChartsKit"],
            swiftSettings: swiftSettings
        ),

        // MARK: Providers

        .target(
            name: "StockChartsKitCSV",
            dependencies: ["StockChartsKit"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StockChartsKitCoinbase",
            dependencies: ["StockChartsKit"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StockChartsKitETrade",
            dependencies: [
                "StockChartsKit",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StockChartsKitSchwab",
            dependencies: ["StockChartsKit"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "StockChartsKitSnapTrade",
            dependencies: [
                "StockChartsKit",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: swiftSettings
        ),

        // MARK: Tests

        .testTarget(
            name: "StockChartsKitTests",
            dependencies: ["StockChartsKit", "StockChartsKitTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitMarketDataTests",
            dependencies: ["StockChartsKitMarketData", "StockChartsKitTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitETradeTests",
            dependencies: ["StockChartsKitETrade", "StockChartsKitTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitCoinbaseTests",
            dependencies: ["StockChartsKitCoinbase", "StockChartsKitTesting"],
            resources: [.copy("Fixtures")],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitSnapTradeTests",
            dependencies: ["StockChartsKitSnapTrade", "StockChartsKitTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitSchwabTests",
            dependencies: ["StockChartsKitSchwab", "StockChartsKitTesting"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "StockChartsKitCSVTests",
            dependencies: ["StockChartsKitCSV", "StockChartsKit"],
            swiftSettings: swiftSettings
        ),
    ],
    swiftLanguageModes: [.v6]
)
