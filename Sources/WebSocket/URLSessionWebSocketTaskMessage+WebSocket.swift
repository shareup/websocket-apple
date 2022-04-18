import Foundation

extension URLSessionWebSocketTask.Message: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .string(text):
            return text
        case let .data(data):
            return "<\(data.count) bytes>"
        @unknown default:
            assertionFailure("Unsupported message: \(self)")
            return "<unknown>"
        }
    }
}

extension WebSocketMessage {
    init(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case let .data(data):
            self = .data(data)
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
