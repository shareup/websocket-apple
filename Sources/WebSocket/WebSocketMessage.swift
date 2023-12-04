import Foundation
import Network

/// An enumeration of the types of messages that can be sent or received.
public enum WebSocketMessage: CustomStringConvertible, Hashable, Sendable {
    /// A WebSocket message that contains a block of data.
    case data(Data)

    /// A WebSocket message that contains a UTF-8 formatted string.
    case text(String)

    public var description: String {
        switch self {
        case let .data(data): String(decoding: data.prefix(100), as: UTF8.self)
        case let .text(text): text
        }
    }
}

public extension WebSocketMessage {
    var stringValue: String? {
        switch self {
        case let .data(data):
            String(data: data, encoding: .utf8)

        case let .text(text):
            text
        }
    }
}

extension WebSocketMessage {
    init(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .data(data):
            self = .data(data)

        case let .string(text):
            self = .text(text)

        @unknown default:
            fatalError("Unhandled message: \(message)")
        }
    }

    var wsMessage: URLSessionWebSocketTask.Message {
        switch self {
        case let .data(data): .data(data)
        case let .text(text): .string(text)
        }
    }
}
