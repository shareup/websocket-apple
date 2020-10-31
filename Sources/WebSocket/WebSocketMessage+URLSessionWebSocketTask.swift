import Foundation
import WebSocketProtocol

extension WebSocketMessage {
    init(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            self = .binary(data)
        case .string(let string):
            self = .text(string)
        @unknown default:
            assertionFailure("Unknown WebSocket Message type")
            self = .text("")
        }
    }
}
