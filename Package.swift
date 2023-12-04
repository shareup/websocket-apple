// swift-tools-version:5.9

import PackageDescription

let package = Package(
    name: "WebSocket",
    platforms: [
        .macOS(.v12), .iOS(.v15), .tvOS(.v15), .watchOS(.v8),
    ],
    products: [
        .library(
            name: "WebSocket",
            targets: ["WebSocket"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/shareup/async-extensions.git",
            from: "4.3.0"
        ),
        .package(
            url: "https://github.com/shareup/dispatch-timer.git",
            from: "3.0.0"
        ),
        .package(
            url: "https://github.com/vapor/websocket-kit.git",
            from: "2.14.0"
        ),
        .package(
            url: "https://github.com/apple/swift-nio.git",
            from: "2.62.0"
        ),
    ],
    targets: [
        .target(
            name: "WebSocket",
            dependencies: [
                .product(name: "AsyncExtensions", package: "async-extensions"),
                .product(name: "DispatchTimer", package: "dispatch-timer"),
            ]
        ),
        .testTarget(
            name: "WebSocketTests",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                "WebSocket",
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ]
        ),
    ]
)
