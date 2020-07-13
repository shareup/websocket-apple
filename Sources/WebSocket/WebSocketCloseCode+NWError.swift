import Foundation
import Network
import WebSocketProtocol

extension WebSocketCloseCode {
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
