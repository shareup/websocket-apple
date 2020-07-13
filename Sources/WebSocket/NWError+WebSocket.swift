import Foundation
import Network
import WebSocketProtocol

extension NWError {
    var isNotConnected: Bool {
        switch self {
        case .posix(.ENOTCONN): return true
        default: return false
        }
    }

    var isCancelled: Bool {
        switch self {
        case .posix(.ECANCELED): return true
        default: return false
        }
    }

    var shouldCloseConnectionWhileConnectingOrOpen: Bool {
        switch self {
        case .posix(.ECANCELED):
            return false
        case .posix(.ENOTCONN):
            return false
        default:
            print("Unhandled error in '\(#function)': \(debugDescription)")
            return true
        }
    }
}

extension NWError {
    var webSocketError: WebSocketError {
        switch self {
        case .posix(.ECANCELED):
            return .closed(.normalClosure, Data(localizedDescription.utf8))
        default:
            print("Unhandled error in '\(#function)': \(debugDescription)")
            return .closed(.normalClosure, Data(localizedDescription.utf8))
        }
    }

    var closeCode: WebSocketCloseCode {
        switch self {
        case .posix(.ECANCELED):
            return .normalClosure
        default:
            print("Unhandled error in '\(#function)': \(debugDescription)")
            return .normalClosure
        }
    }
}
