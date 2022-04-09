import Foundation

public struct WebSocketClient {
    public var onStateChange: (@escaping (WebSocketEvent) -> Void) async -> Void

    /// Sends a close frame to the server with the given close code.
    public var close: (WebSocketCloseCode) async throws -> Void

    /// Sends the WebSocket binary message.
    public var sendBinary: (Data) async throws -> Void

    /// Sends the WebSocket text message.
    public var sendText: (String) async throws -> Void

    /// Receives a message from the WebSocket.
    public var receiveMessage: () async throws -> WebSocketMessage
}

public extension WebSocketClient {
    /// Calls `WebSocketProtocol.close(closeCode: .goingAway)`.
    func close() async throws {
        try await self.close(.goingAway)
    }

    func receiveText() async throws -> String {
        guard case let .text(text) = try await self.receiveMessage()
        else { throw WebSocketError.expectedTextReceivedData }
        return text
    }

    func receiveData() async throws -> Data {
        guard case let .data(data) = try await self.receiveMessage()
        else { throw WebSocketError.expectedDataReceivedText }
        return data
    }
}

public extension WebSocketClient {
    static func system(
        url: URL,
        options: WebSocketOptions = .init(),
        onStateChange: @escaping (WebSocketEvent) -> Void
    ) async -> Self {
        let ws = await WebSocket(
            url: url,
            options: options,
            onStateChange: onStateChange
        )

        return Self(
            onStateChange: { await ws.setOnStateChange($0) },
            close: { await ws.close($0) },
            sendBinary: { try await ws.send(.data($0)) },
            sendText: { try await ws.send(.string($0)) },
            receiveMessage: {
                switch try await ws.receive() {
                case let .data(data):
                    return .data(data)

                case let .string(text):
                    return .text(text)

                @unknown default:
                    throw WebSocketError.receiveUnknownMessageType
                }
            }
        )
    }
}
