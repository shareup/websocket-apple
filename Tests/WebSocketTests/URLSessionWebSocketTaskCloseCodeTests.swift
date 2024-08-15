@testable import WebSocket
import XCTest

class URLSessionWebSocketTaskCloseCodeTests: XCTestCase {
    func testCanInitializeURLSessionWebSocketTaskCloseCode() throws {
        let urlSessionCloseCodes: [URLSessionWebSocketTask.CloseCode] = [
            .invalid, .normalClosure, .goingAway, .protocolError, .unsupportedData,
            .noStatusReceived, .abnormalClosure, .invalidFramePayloadData, .policyViolation,
            .messageTooBig, .mandatoryExtensionMissing, .internalServerError,
            .tlsHandshakeFailure,
        ]

        let closeCodes: [WebSocketCloseCode] = [
            .invalid, .normalClosure, .goingAway, .protocolError, .unsupportedData,
            .noStatusReceived, .abnormalClosure, .invalidFramePayloadData, .policyViolation,
            .messageTooBig, .mandatoryExtensionMissing, .internalServerError,
            .tlsHandshakeFailure,
        ]

        for (urlSessionCloseCode, closeCode) in zip(urlSessionCloseCodes, closeCodes) {
            XCTAssertEqual(urlSessionCloseCode, closeCode.wsCloseCode)
        }
    }
}
