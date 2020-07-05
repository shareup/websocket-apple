import Foundation
import WebSocketProtocol

extension URLSessionWebSocketTask.CloseCode {
    public init?(_ closeCode: WebSocketCloseCode) {
        self.init(rawValue: closeCode.rawValue)
    }
}
