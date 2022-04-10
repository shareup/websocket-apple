// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WebSocket",
    platforms: [
        .macOS(.v11), .iOS(.v14), .tvOS(.v14), .watchOS(.v7),
    ],
    products: [
        .library(
            name: "WebSocket",
            targets: ["WebSocket"]
        )],
    dependencies: [
        .package(
            name: "Synchronized",
            url: "https://github.com/shareup/synchronized.git",
            from: "3.0.0"
        ),
        .package(name: "swift-nio", url: "https://github.com/apple/swift-nio.git", from: "2.39.0"),
        .package(name: "swift-nio-ssl", url: "https://github.com/apple/swift-nio-ssl.git", from: "2.18.0"),
    ],
    targets: [
        .target(
            name: "WebSocket",
            dependencies: ["Synchronized"]),
        .testTarget(
            name: "WebSocketTests",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                "WebSocket",
            ])
    ]
)
