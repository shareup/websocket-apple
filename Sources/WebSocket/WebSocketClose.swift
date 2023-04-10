import Foundation

public struct WebSocketClose: Hashable, CustomStringConvertible, Sendable {
    public let code: WebSocketCloseCode
    public let reason: Data?

    public init(_ code: WebSocketCloseCode, _ reason: Data?) {
        self.code = code
        self.reason = reason
    }

    public var description: String { "\(code.description)" }
}

public extension WebSocketClose {
    var isNormal: Bool {
        switch code {
        case .normalClosure: return true
        default: return false
        }
    }

    var isCancelled: Bool {
        switch code {
        case .cancelled: return true
        default: return false
        }
    }
}
