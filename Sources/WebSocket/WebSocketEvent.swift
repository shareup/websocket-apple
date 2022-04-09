import Foundation

/// Lifecycle events related to the opening or closing of the WebSocket.
public enum WebSocketEvent: Hashable, CustomStringConvertible {
    /// Fired when a connection with a WebSocket is opened.
    case open

    /// Fired when a connection with a WebSocket is closed.
    case close(WebSocketCloseCode?, Data?)

    /// Fired when a connection with a WebSocket has been closed because of an error,
    /// such as when some data couldn't be sent.
    case error(NSError?)

    public var description: String {
        switch self {
        case .open:
            return "open"

        case let .close(code, reason):
            if let reason = reason {
                return "close(\(code?.rawValue ?? -1), \(String(data: reason, encoding: .utf8) ?? ""))"
            } else {
                return "close(\(code?.rawValue ?? -1))"
            }

        case let .error(error):
            return "error(\(error?.localizedDescription ?? ""))"
        }
    }
}
