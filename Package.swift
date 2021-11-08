// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "WebSocket",
    platforms: [
        .macOS(.v10_15), .iOS(.v13), .tvOS(.v13), .watchOS(.v6),
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
        .package(
            name: "WebSocketProtocol",
            url: "https://github.com/shareup/websocket-protocol.git",
            from: "2.3.2"
        ),
        .package(name: "swift-nio", url: "https://github.com/apple/swift-nio.git", from: "2.0.0")],
    targets: [
        .target(
            name: "WebSocket",
            dependencies: ["Synchronized", "WebSocketProtocol"]),
        .testTarget(
            name: "WebSocketTests",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                "WebSocket",
            ])
    ]
)
