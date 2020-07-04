import Foundation
import WebSocketProtocol

extension WebSocketMessage {
    init(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            self = .data(data)
        case .string(let string):
            self = .string(string)
        @unknown default:
            assertionFailure("Unknown WebSocket Message type")
            self = .string("")
        }
    }
}
