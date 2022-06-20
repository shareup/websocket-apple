@preconcurrency import Foundation
import Network

public enum WebSocketError: Error, Equatable {
    case closed
    case connectionError(NWError)
    case invalidURL(URL)
    case invalidURLComponents(URLComponents)
    case openAfterConnectionClosed
    case receiveMessageWhenNotOpen
    case receiveUnknownMessageType
    case sendMessageWhileConnecting
}

extension Optional where Wrapped == WebSocketError {
    var debugDescription: String {
        guard case let .some(error) = self else { return "" }
        return String(reflecting: error)
    }
}
