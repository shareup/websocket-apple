import Foundation
import Combine

public typealias WebSocketOnOpen = () -> Void
public typealias WebSocketOnClose = (WebSocketCloseResult) -> Void

public struct WebSocket {
    /// Sets a closure to be called when the WebSocket connects successfully.
    public var onOpen: (@escaping WebSocketOnOpen) async -> Void

    /// Sets a closure to be called when the WebSocket closes.
    public var onClose: (@escaping WebSocketOnClose) async -> Void

    /// Opens the WebSocket connect with an optional timeout. After this function
    /// is awaited, the WebSocket connection is open ready to be used. If the
    /// connection fails or times out, an error is thrown.
    public var open: (TimeInterval?) async throws -> Void

    /// Sends a close frame to the server with the given close code.
    public var close: (WebSocketCloseCode) async throws -> Void

    /// Sends a text or binary message.
    public var send: (WebSocketMessage) async throws -> Void

    /// Publishes messages received from WebSocket. Finishes when the
    /// WebSocket connection closes.
    public var messagesPublisher: () -> AnyPublisher<WebSocketMessage, Never>

    public init(
        onOpen: @escaping ((@escaping WebSocketOnOpen)) async -> Void = { _ in },
        onClose: @escaping ((@escaping WebSocketOnClose)) async -> Void = { _ in },
        open: @escaping (TimeInterval?) async throws -> Void = { _ in },
        close: @escaping (WebSocketCloseCode) async throws -> Void = { _ in },
        send: @escaping (WebSocketMessage) async throws -> Void = { _ in },
        messagesPublisher: @escaping () -> AnyPublisher<WebSocketMessage, Never> = {
            Empty<WebSocketMessage, Never>(completeImmediately: false).eraseToAnyPublisher()
        }
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
        self.open = open
        self.close = close
        self.send = send
        self.messagesPublisher = messagesPublisher
    }
}

public extension WebSocket {
    /// Calls `WebSocket.open(nil)`.
    func open() async throws {
        try await open(nil)
    }

    /// Calls `WebSocket.close(closeCode: .goingAway)`.
    func close() async throws {
        try await close(.goingAway)
    }

    /// The WebSocket's received messages as an asynchronous stream.
    var messages: AsyncStream<WebSocketMessage> {
        var cancellable: AnyCancellable?

        return AsyncStream { cont in
            func finish() {
                if cancellable != nil {
                    cont.finish()
                    cancellable = nil
                }
            }

            let _cancellable = self.messagesPublisher()
                .handleEvents(receiveCancel: { finish() })
                .sink(
                    receiveCompletion: { _ in finish() },
                    receiveValue: { cont.yield($0) }
                )

            cancellable = _cancellable
        }
    }
}

public extension WebSocket {
    /// System WebSocket implementation powered by the Network Framework.
    static func system(
        url: URL,
        options: WebSocketOptions = .init(),
        onOpen: @escaping WebSocketOnOpen = {},
        onClose: @escaping WebSocketOnClose = { _ in }
    ) async throws -> Self {
        let ws = try await SystemWebSocket(
            url: url,
            options: options,
            onOpen: onOpen,
            onClose: onClose
        )
        return try await .system(ws)
    }

    // This is only intended for use in tests.
    internal static func system(_ ws: SystemWebSocket) async throws -> Self {
        Self(
            onOpen: { onOpen in await ws.onOpen(onOpen) },
            onClose: { onClose in await ws.onClose(onClose) },
            open: { timeout in try await ws.open(timeout: timeout) },
            close: { code in try await ws.close(code) },
            send: { message in try await ws.send(message) },
            messagesPublisher: { ws.eraseToAnyPublisher() }
        )
    }
}
