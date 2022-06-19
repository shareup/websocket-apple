// swift-tools-version:5.5
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
        ),
    ],
    dependencies: [],
    targets: [
        .target(
            name: "WebSocket",
            dependencies: []
        ),
        .testTarget(
            name: "WebSocketTests",
            dependencies: ["WebSocket"]
        ),
    ]
)
