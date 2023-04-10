import Foundation
import Network

public enum WebSocketError: Error, Equatable {
    case closeCodeAndReason(WebSocketCloseCode, Data?)
    case invalidURL(URL)
    case sendMessageWhileConnecting

    init(_ closeCode: WebSocketCloseCode?, _ reason: Data?) {
        self = .closeCodeAndReason(
            closeCode ?? .unknown,
            reason
        )
    }

    var closeCode: WebSocketCloseCode? {
        guard case let .closeCodeAndReason(code, _) = self
        else { return nil }
        return code
    }

    var reason: Data? {
        guard case let .closeCodeAndReason(_, reason) = self
        else { return nil }
        return reason
    }
}
