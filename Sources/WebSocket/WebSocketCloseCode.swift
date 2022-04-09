import Foundation

/// A code indicating why a WebSocket connection closed.
///
/// Mirrors [URLSessionWebSocketTask](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask/closecode).
public enum WebSocketCloseCode: Int, CaseIterable {

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
