@preconcurrency import Foundation
import Network

/// An enumeration of the types of messages that can be sent or received.
public enum WebSocketMessage: CustomStringConvertible, CustomDebugStringConvertible, Hashable,
    Sendable
{
    /// A WebSocket message that contains a block of data.
    case data(Data)

    /// A WebSocket message that contains a UTF-8 formatted string.
    case text(String)

    public var description: String {
        switch self {
        case let .data(data): return String(decoding: data.prefix(100), as: UTF8.self)
        case let .text(text): return text
        }
    }

    public var debugDescription: String { description }
}

public extension WebSocketMessage {
    var stringValue: String? {
        switch self {
        case let .data(data):
            return String(data: data, encoding: .utf8)

        case let .text(text):
            return text
        }
    }
}
