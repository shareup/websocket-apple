import Foundation
import Network

/// A code indicating why a WebSocket connection closed.
///
/// Mirrors [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask/closecode).
public enum WebSocketCloseCode: Int, CaseIterable, Sendable {
    /// A code that indicates the connection is still open.
    case invalid = 0

    /// A code that indicates normal connection closure.
    case normalClosure = 1000

    /// A code that indicates an endpoint is going away.
    case goingAway = 1001

    /// A code that indicates an endpoint terminated the connection due to a protocol error.
    case protocolError = 1002

    /// A code that indicates an endpoint terminated the connection after receiving a type of data it can’t accept.
    case unsupportedData = 1003

    /// A reserved code that indicates an endpoint expected a status code and didn’t receive one.
    case noStatusReceived = 1005

    /// A reserved code that indicates the connection closed without a close control frame.
    case abnormalClosure = 1006

    /// A code that indicates the server terminated the connection because it received data inconsistent with the message’s type.
    case invalidFramePayloadData = 1007

    /// A code that indicates an endpoint terminated the connection because it received a message that violates its policy.
    case policyViolation = 1008

    /// A code that indicates an endpoint is terminating the connection because it received a message too big for it to process.
    case messageTooBig = 1009

    /// A code that indicates the client terminated the connection because the server didn’t negotiate a required extension.
    case mandatoryExtensionMissing = 1010

    /// A code that indicates the server terminated the connection because it encountered an unexpected condition.
    case internalServerError = 1011

    /// A reserved code that indicates the connection closed due to the failure to perform a TLS handshake.
    case tlsHandshakeFailure = 1015
}

extension WebSocketCloseCode {
    var nwCloseCode: NWProtocolWebSocket.CloseCode {
        switch self {
        case .invalid: return .privateCode(0)
        case .normalClosure: return .protocolCode(.normalClosure)
        case .goingAway: return .protocolCode(.goingAway)
        case .protocolError: return .protocolCode(.protocolError)
        case .unsupportedData: return .protocolCode(.unsupportedData)
        case .noStatusReceived: return .protocolCode(.noStatusReceived)
        case .abnormalClosure: return .protocolCode(.abnormalClosure)
        case .invalidFramePayloadData: return .protocolCode(.invalidFramePayloadData)
        case .policyViolation: return .protocolCode(.policyViolation)
        case .messageTooBig: return .protocolCode(.messageTooBig)
        case .mandatoryExtensionMissing: return .protocolCode(.mandatoryExtension)
        case .internalServerError: return .protocolCode(.internalServerError)
        case .tlsHandshakeFailure: return .protocolCode(.tlsHandshake)
        }
    }

    var error: NWError? {
        switch self {
        case .invalid:
            return nil
        case .normalClosure:
            return nil
        case .goingAway:
            return nil
        case .protocolError:
            return .posix(.EPROTO)
        case .unsupportedData:
            return .posix(.EBADMSG)
        case .noStatusReceived:
            return nil
        case .abnormalClosure:
            return nil
        case .invalidFramePayloadData:
            return nil
        case .policyViolation:
            return nil
        case .messageTooBig:
            return .posix(.EMSGSIZE)
        case .mandatoryExtensionMissing:
            return nil
        case .internalServerError:
            return nil
        case .tlsHandshakeFailure:
            return .tls(errSSLHandshakeFail)
        }
    }
}
