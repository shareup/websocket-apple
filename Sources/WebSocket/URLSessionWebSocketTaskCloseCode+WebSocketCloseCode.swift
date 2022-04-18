import Foundation

extension URLSessionWebSocketTask.CloseCode {
    init?(_ closeCode: WebSocketCloseCode) {
        self.init(rawValue: closeCode.rawValue)
    }
}

extension WebSocketCloseCode {
    init?(_ closeCode: URLSessionWebSocketTask.CloseCode?) {
        guard let closeCode = closeCode else { return nil }
        self.init(rawValue: closeCode.rawValue)
    }

    var urlSessionCloseCode: URLSessionWebSocketTask.CloseCode {
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
        }
    }
}
