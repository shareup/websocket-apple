import Foundation
import Network

public enum WebSocketError: Error, Equatable {
    case invalidURL(URL)
    case invalidURLComponents(URLComponents)
    case openAfterConnectionClosed
    case sendMessageWhileConnecting
    case receiveMessageWhenNotOpen
    case receiveUnknownMessageType
    case connectionError(NWError)
}

extension Optional where Wrapped == WebSocketError {
    var debugDescription: String {
        guard case let .some(error) = self else { return "" }
        return String(reflecting: error)
    }
}
