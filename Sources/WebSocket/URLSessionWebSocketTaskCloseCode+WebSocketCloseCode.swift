import Foundation
import WebSocketProtocol

public extension URLSessionWebSocketTask.CloseCode {
    init?(_ closeCode: WebSocketCloseCode) {
        self.init(rawValue: closeCode.rawValue)
    }
}
