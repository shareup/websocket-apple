import Foundation
import WebSocketProtocol

extension WebSocketMessage {
    init(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .data(data):
            self = .binary(data)
        case let .string(string):
            self = .text(string)
        @unknown default:
            assertionFailure("Unknown WebSocket Message type")
            self = .text("")
        }
    }
}

extension Result: CustomDebugStringConvertible where Success == WebSocketMessage {
    public var debugDescription: String {
        switch self {
        case let .success(message):
            return message.debugDescription
        case let .failure(error):
            return error.localizedDescription
        }
    }
}
