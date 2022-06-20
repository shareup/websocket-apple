// swift-tools-version:5.6
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
    dependencies: [
        .package(
            url: "https://github.com/shareup/dispatch-timer.git",
            from: "2.1.2"
        ),
    ],
    targets: [
        .target(
            name: "WebSocket",
            dependencies: [
                .product(name: "DispatchTimer", package: "dispatch-timer"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-Xfrontend", "-warn-concurrency",
                ]),
            ]
        ),
        .testTarget(
            name: "WebSocketTests",
            dependencies: ["WebSocket"]
        ),
    ]
)
