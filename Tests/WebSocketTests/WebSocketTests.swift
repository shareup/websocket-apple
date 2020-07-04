import XCTest
import Combine
import WebSocketProtocol
@testable import WebSocket

class WebSocketTests: XCTestCase {
    let port: UInt16 = 54321
    var url: URL { URL(string: "ws://0.0.0.0:\(port)/socket")! }

    func testCanConnectToAndDisconnectFromServer() throws {
        try withServer { (server) in
            let webSocket = WebSocket(url: url)

            let sub = webSocket.sink(
                receiveCompletion: expectFinished(),
                receiveValue: expectValueAndThen(WebSocketMessage.open, webSocket.close())
            )
            defer { sub.cancel() }

            waitForExpectations(timeout: 2)
        }
    }

    func testCompleteWhenRemoteCloses() throws {
        try withServer { (server) in
            let webSocket = WebSocket(url: url)

            var invalidUTF8Bytes = [0x192, 0x193] as [UInt16]
            let bytes = withUnsafeBytes(of: &invalidUTF8Bytes) { Array($0) }
            let data = Data(bytes: bytes, count: bytes.count)

            let openEx = self.expectation(description: "Should have opened")
            let errorEx = self.expectation(description: "Should have errored")
            let sub = webSocket.sink(
                receiveCompletion: expectFailure(),
                receiveValue: { result in
                    switch result {
                    case .success(.open):
                        webSocket.send(data)
                        openEx.fulfill()
                    case .failure:
                        errorEx.fulfill()
                    default:
                        break
                    }
                }
            )
            defer { sub.cancel() }

            waitForExpectations(timeout: 2)
        }
    }

//    func testJoinLobby() throws {
//        let completeEx = expectation(description: "WebSocket pipeline is complete")
//        let openEx = expectation(description: "WebSocket should be open")
//
//        let webSocket = WebSocket(url: testHelper.defaultWebSocketURL)
//
//        let sub = webSocket.sink(receiveCompletion: { completion in
//            if case .finished = completion {
//                completeEx.fulfill()
//            }
//        }) {
//            if case .success(.open) = $0 { return openEx.fulfill() }
//        }
//        defer { sub.cancel() }
//
//        wait(for: [openEx], timeout: 0.5)
//        XCTAssert(webSocket.isOpen)
//
//        let joinRef = testHelper.gen.advance().rawValue
//        let ref = testHelper.gen.current.rawValue
//        let topic = "room:lobby"
//        let event = "phx_join"
//        let payload = [String: String]()
//
//        let message = testHelper.serialize([
//            joinRef,
//            ref,
//            topic,
//            event,
//            payload
//        ])!
//
//        webSocket.send(message) { error in
//            if let error = error {
//                XCTFail("Sending data down the socket failed \(error)")
//            }
//        }
//
//        var hasReplied = false
//        let hasRepliedEx = expectation(description: "Should have replied")
//        var reply: [Any?] = []
//
//        let sub2 = webSocket.sink(receiveCompletion: { completion in
//            if case .failure = completion {
//                XCTFail("Should not have failed")
//            }
//        }) { result in
//            guard !hasReplied else { return }
//
//            let message: WebSocketMessage
//
//            hasReplied = true
//
//            switch result {
//            case .success(let _message):
//                message = _message
//            case .failure(let error):
//                XCTFail("Received an error \(error)")
//                return
//            }
//
//            switch message {
//            case .data(_):
//                XCTFail("Received a data response, which is wrong")
//            case .string(let string):
//                reply = testHelper.deserialize(string.data(using: .utf8)!)!
//            case .open:
//                XCTFail("Received an open event")
//            }
//
//            hasRepliedEx.fulfill()
//        }
//        defer { sub2.cancel() }
//
//        wait(for: [hasRepliedEx], timeout: 0.5)
//        XCTAssert(hasReplied)
//
//        if reply.count == 5 {
//            XCTAssertEqual(reply[0] as! UInt64, joinRef)
//            XCTAssertEqual(reply[1] as! UInt64, ref)
//            XCTAssertEqual(reply[2] as! String, "room:lobby")
//            XCTAssertEqual(reply[3] as! String, "phx_reply")
//
//            let rp = reply[4] as! [String: Any?]
//
//            XCTAssertEqual(rp["status"] as! String, "ok")
//            XCTAssertEqual(rp["response"] as! [String: String], [:])
//        } else {
//            XCTFail("Reply wasn't the right shape")
//        }
//
//        webSocket.close()
//
//        wait(for: [completeEx], timeout: 0.5)
//        XCTAssert(webSocket.isClosed)
//    }
//
//    func testEcho() {
//        let completeEx = expectation(description: "WebSocket pipeline is complete")
//        let openEx = expectation(description: "WebSocket should be open")
//
//        let webSocket = WebSocket(url: testHelper.defaultWebSocketURL)
//
//        let sub = webSocket.sink(receiveCompletion: { completion in
//            if case .finished = completion {
//                completeEx.fulfill()
//            }
//        }) {
//            if case .success(.open) = $0 { return openEx.fulfill() }
//        }
//        defer { sub.cancel() }
//
//        wait(for: [openEx], timeout: 0.5)
//        XCTAssert(webSocket.isOpen)
//
//        let joinRef = testHelper.gen.advance().rawValue
//        let ref = testHelper.gen.current.rawValue
//        let topic = "room:lobby"
//        let event = "phx_join"
//        let payload = [String: String]()
//
//        // for later
//        let nextRef = testHelper.gen.advance().rawValue
//
//        let message = testHelper.serialize([
//            joinRef,
//            ref,
//            topic,
//            event,
//            payload
//        ])!
//
//        webSocket.send(message) { error in
//            if let error = error {
//                XCTFail("Sending data down the socket failed \(error)")
//            }
//        }
//
//        let repliesEx = expectation(description: "Should receive 6 replies")
//        repliesEx.expectedFulfillmentCount = 7
//
//        /*
//         1.   Channel join response
//         2-6. Repeat responses
//         7.   Reponse from asking for the repeat to happen
//
//         It's possible the response from asking for the repeat to happen could be before, during, or after the repeat messages themselves.
//         */
//
//        let sub2 = webSocket.sink(receiveCompletion: {
//            completion in print("$$$ Websocket publishing complete")
//        }) { result in
//            let message: WebSocketMessage
//
//            switch result {
//            case .success(let _message):
//                message = _message
//            case .failure(let error):
//                XCTFail("Received an error \(error)")
//                return
//            }
//
//            switch message {
//            case .data(_):
//                XCTFail("Received a data response, which is wrong")
//            case .string(let string):
//                let reply = try! IncomingMessage(data: string.data(using: .utf8)!)
//                print("reply: \(reply)")
//                repliesEx.fulfill()
//
//                guard let _joinRef = reply.joinRef else { return }
//                guard let _ref = reply.ref else { return }
//
//                if _joinRef.rawValue == joinRef && _ref.rawValue == ref {
//                    let repeatEvent = "repeat"
//                    let repeatPayload: [String: Any] = [
//                        "echo": "hello",
//                        "amount": 5
//                    ]
//
//                    let message = testHelper.serialize([
//                        joinRef,
//                        nextRef,
//                        topic,
//                        repeatEvent,
//                        repeatPayload
//                    ])!
//
//                    webSocket.send(message) { error in
//                        if let error = error {
//                            XCTFail("Sending data down the socket failed \(error)")
//                        }
//                    }
//
//                    return
//                }
//
//                if _joinRef.rawValue == joinRef && _ref.rawValue == nextRef {
//                    print("OK, got the response from the repeat trigger message")
//                }
//            case .open:
//                XCTFail("Received an open event")
//            }
//        }
//        defer { sub2.cancel() }
//
//        wait(for: [repliesEx], timeout: 0.5)
//
//        webSocket.close()
//
//        wait(for: [completeEx], timeout: 0.5)
//        XCTAssert(webSocket.isClosed)
//    }
}

private extension WebSocketTests {
    func withServer(_ block: (WebSocketServer) throws -> Void) throws {
        let server = WebSocketServer(port: port, replyProvider: .reply { nil })
        try withExtendedLifetime(server) { server.listen(); try block(server) }
    }

    func withEchoServer(_ block: (WebSocketServer) throws -> Void) throws {
        let server = WebSocketServer(port: port, replyProvider: .echo)
        try withExtendedLifetime(server) { server.listen(); try block(server) }
    }

    func withReplyServer(_ replies: Array<String?>, _ block: (WebSocketServer) throws -> Void) throws {
        var replies = replies
        let provider: () -> String? = { return replies.removeFirst() }
        let server = WebSocketServer(port: port, replyProvider: .reply(provider))
        try withExtendedLifetime(server) { server.listen(); try block(server) }
    }
}

private extension WebSocketTests {
    func expectValue<T: Equatable, E: Error>(_ value: T) -> (Result<T, E>) -> Void {
        return self.expectValues([value])
    }

    func expectValues<T: Equatable, E: Error>(_ values: Array<T>) -> (Result<T, E>) -> Void {
        var values = values
        let expectation = self.expectation(description: "Should have received \(String(describing: values))")
        return { (result: Result<T, E>) in
            guard case let .success(value) = result else {
                return XCTFail("Unexpected result: \(String(describing: result))")
            }

            let expected = values.removeFirst()
            XCTAssertEqual(expected, value)
            if values.isEmpty {
                expectation.fulfill()
            }
        }
    }

    func expectValueAndThen<T: Hashable, E: Error>(
        _ value: T,
        _ block: @escaping @autoclosure () -> Void) -> (Result<T, E>) -> Void
    {
        return self.expectValuesAndThen([value: block])
    }

    func expectValuesAndThen<T: Hashable, E: Error>(_ values: Dictionary<T, () -> Void>) -> (Result<T, E>) -> Void {
        var values = values
        let expectation = self.expectation(description: "Should have received \(String(describing: values))")
        return { (result: Result<T, E>) in
            guard case let .success(value) = result else {
                return XCTFail("Unexpected result: \(String(describing: result))")
            }

            let block = values.removeValue(forKey: value)
            XCTAssertNotNil(block)
            block?()

            if values.isEmpty {
                expectation.fulfill()
            }
        }
    }

    func expectFinished<E: Error>() -> (Subscribers.Completion<E>) -> Void {
        let expectation = self.expectation(description: "Should have finished successfully")
        return { completion in
            guard case Subscribers.Completion.finished = completion else { return }
            expectation.fulfill()
        }
    }

    func expectFailure<E>() -> (Subscribers.Completion<E>) -> Void where E: Error {
        let expectation = self.expectation(description: "Should have failed")
        return { completion in
            guard case Subscribers.Completion.failure = completion else { return }
            expectation.fulfill()
        }
    }

    func expectFailure<E>(_ error: E? = nil) -> (Subscribers.Completion<E>) -> Void where E: Error, E: Equatable {
        let expectation = self.expectation(description: "Should have failed")
        return { completion in
            guard case Subscribers.Completion.failure(error) = completion else { return }
            expectation.fulfill()
        }
    }
}
