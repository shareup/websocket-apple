import Combine
@preconcurrency import Foundation

public typealias WebSocketOnOpen = @Sendable () -> Void
public typealias WebSocketOnClose = @Sendable (WebSocketClose)
    -> Void

public struct WebSocket: Identifiable, Sendable {
    public var id: Int

    /// Sets a closure to be called when the WebSocket connects successfully.
    public var onOpen: WebSocketOnOpen

    /// Sets a closure to be called when the WebSocket closes.
    public var onClose: WebSocketOnClose

    /// Opens the WebSocket connect with an optional timeout. After this function
    /// is awaited, the WebSocket connection is open ready to be used. If the
    /// connection fails or times out, an error is thrown.
    public var open: @Sendable (TimeInterval?) async throws -> Void

    /// Sends a close frame to the server with the given close code.
    public var close: @Sendable (WebSocketCloseCode, TimeInterval?) async throws -> Void

    /// Sends a text or binary message.
    public var send: @Sendable (WebSocketMessage) async throws -> Void

    /// Publishes messages received from WebSocket. Finishes when the
    /// WebSocket connection closes.
    public var messagesPublisher: @Sendable ()
        -> AnyPublisher<WebSocketMessage, Never>

    public init(
        id: Int,
        onOpen: @escaping WebSocketOnOpen = {},
        onClose: @escaping WebSocketOnClose = { _ in },
        open: @escaping @Sendable (TimeInterval?) async throws -> Void = { _ in },
        close: @escaping @Sendable (WebSocketCloseCode, TimeInterval?) async throws
            -> Void = { _, _ in },
        send: @escaping @Sendable (WebSocketMessage) async throws -> Void = { _ in },
        messagesPublisher: @escaping @Sendable () -> AnyPublisher<WebSocketMessage, Never> = {
            Empty<WebSocketMessage, Never>(completeImmediately: false).eraseToAnyPublisher()
        }
    ) {
        self.id = id
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

    /// Calls `WebSocket.close(.normalClosure, nil)`.
    func close() async throws {
        try await close(.normalClosure, nil)
    }

    /// Calls `WebSocket.close(.normalClosure, timeout)`.
    func close(timeout: TimeInterval) async throws {
        try await close(.normalClosure, timeout)
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
            id: Int(bitPattern: ObjectIdentifier(ws)),
            onOpen: ws.onOpen,
            onClose: ws.onClose,
            open: { timeout in try await ws.open(timeout: timeout) },
            close: { code, timeout in try await ws.close(code, timeout: timeout) },
            send: { message in try await ws.send(message) },
            messagesPublisher: { ws.eraseToAnyPublisher() }
        )
    }
}
