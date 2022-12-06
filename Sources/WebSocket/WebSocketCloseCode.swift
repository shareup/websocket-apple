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

    /// A code that indicates an endpoint terminated the connection due to a
    /// protocol error.
    case protocolError = 1002

    /// A code that indicates an endpoint terminated the connection after
    /// receiving a type of data it can’t accept.
    case unsupportedData = 1003

    /// A reserved code that indicates an endpoint expected a status code and
    /// didn’t receive one.
    case noStatusReceived = 1005

    /// A reserved code that indicates the connection closed without a close
    /// control frame.
    case abnormalClosure = 1006

    /// A code that indicates the server terminated the connection because it
    /// received data inconsistent with the message’s type.
    case invalidFramePayloadData = 1007

    /// A code that indicates an endpoint terminated the connection because it
    /// received a message that violates its policy.
    case policyViolation = 1008

    /// A code that indicates an endpoint is terminating the connection because
    /// it received a message too big for it to process.
    case messageTooBig = 1009

    /// A code that indicates the client terminated the connection because the
    /// server didn’t negotiate a required extension.
    case mandatoryExtensionMissing = 1010

    /// A code that indicates the server terminated the connection because it
    /// encountered an unexpected condition.
    case internalServerError = 1011

    /// A reserved code that indicates the connection closed due to the failure
    /// to perform a TLS handshake.
    case tlsHandshakeFailure = 1015

    // NOTE: Status codes in the range 4000-4999 are reserved for private use
    // and thus can't be registered.  Such codes can be used by prior
    // agreements between WebSocket applications.  The interpretation of
    // these codes is undefined by this protocol.
    //
    // https://www.rfc-editor.org/rfc/rfc6455#section-7.4.1

    /// A code that indicates the connection closed because it was cancelled by
    /// the client.
    case cancelled = 4000

    /// A code that indicates the connection failed to open because it had
    /// already been closed.
    case alreadyClosed = 4001

    /// A code that indicates the connection timed out while opening.
    case timeout = 4002

    /// A code that indicates the connection closed because of an unknown reason.
    case unknown = 4999
}

extension WebSocketCloseCode: CustomStringConvertible {
    public var description: String {
        switch self {
        case .invalid: return "invalid"
        case .normalClosure: return "normalClosure"
        case .goingAway: return "goingAway"
        case .protocolError: return "protocolError"
        case .unsupportedData: return "unsupportedData"
        case .noStatusReceived: return "noStatusReceived"
        case .abnormalClosure: return "abnormalClosure"
        case .invalidFramePayloadData: return "invalidFramePayloadData"
        case .policyViolation: return "policyViolation"
        case .messageTooBig: return "messageTooBig"
        case .mandatoryExtensionMissing: return "mandatoryExtensionMissing"
        case .internalServerError: return "internalServerError"
        case .tlsHandshakeFailure: return "tlsHandshakeFailure"
        case .cancelled: return "cancelled"
        case .alreadyClosed: return "alreadyClosed"
        case .timeout: return "timeout"
        case .unknown: return "unknown"
        }
    }
}

extension WebSocketCloseCode {
    init(_ code: URLSessionWebSocketTask.CloseCode) {
        switch code {
        case .invalid:
            self = .invalid
        case .normalClosure:
            self = .normalClosure
        case .goingAway:
            self = .goingAway
        case .protocolError:
            self = .protocolError
        case .unsupportedData:
            self = .unsupportedData
        case .noStatusReceived:
            self = .noStatusReceived
        case .abnormalClosure:
            self = .abnormalClosure
        case .invalidFramePayloadData:
            self = .invalidFramePayloadData
        case .policyViolation:
            self = .policyViolation
        case .messageTooBig:
            self = .messageTooBig
        case .mandatoryExtensionMissing:
            self = .mandatoryExtensionMissing
        case .internalServerError:
            self = .internalServerError
        case .tlsHandshakeFailure:
            self = .tlsHandshakeFailure
        @unknown default:
            self = .unknown
        }
    }

    var wsCloseCode: URLSessionWebSocketTask.CloseCode? {
        switch self {
        case .invalid: return .invalid
        case .normalClosure: return .normalClosure
        case .goingAway: return .goingAway
        case .protocolError: return .protocolError
        case .unsupportedData: return .unsupportedData
        case .noStatusReceived: return .noStatusReceived
        case .abnormalClosure: return .abnormalClosure
        case .invalidFramePayloadData: return .invalidFramePayloadData
        case .policyViolation: return .policyViolation
        case .messageTooBig: return .messageTooBig
        case .mandatoryExtensionMissing: return .mandatoryExtensionMissing
        case .internalServerError: return .internalServerError
        case .tlsHandshakeFailure: return .tlsHandshakeFailure
        case .cancelled: return nil
        case .alreadyClosed: return nil
        case .timeout: return nil
        case .unknown: return nil
        }
    }
}
