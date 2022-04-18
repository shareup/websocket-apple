import Foundation
import Network

/// An enumeration of the types of messages that can be sent or received.
public enum WebSocketMessage: CustomStringConvertible, CustomDebugStringConvertible, Hashable {
    /// A WebSocket message that contains a block of data.
    case data(Data)

    /// A WebSocket message that contains a UTF-8 formatted string.
    case text(String)

    public var description: String {
        switch self {
        case let .data(data): return "\(data.count) bytes"
        case let .text(text): return text
        }
    }

    public var debugDescription: String { description }
}
