import Foundation
import Network

public typealias WebSocketClose = (
    code: WebSocketCloseCode,
    error: WebSocketError?
)
