import XCTest
import Combine
import WebSocketProtocol
@testable import WebSocket

private var ports = (50000...52000).map { UInt16($0) }

class WebSocketTests: XCTestCase {
    func url(_ port: UInt16) -> URL { URL(string: "ws://0.0.0.0:\(port)/socket")! }

    func testCanConnectToAndDisconnectFromServer() throws {
        try withServer { (server, client) in
            let sub = client.sink(
                receiveCompletion: expectFinished(),
                receiveValue: expectValueAndThen(WebSocketMessage.open, client.close())
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)

            XCTAssertFalse(client.isOpen)
            XCTAssertTrue(client.isClosed)
        }
    }

    func testCompleteWhenServerIsUnreachable() throws {
        try withServer { (server, client) in
            server.close()

            let errorEx = self.expectation(description: "Should have received error")
            let sub = client.sink(
                receiveCompletion: expectFailure(),
                receiveValue: { result in
                    switch result {
                    case let .failure(error as NSError):
                        XCTAssertEqual("NSURLErrorDomain", error.domain)
                        XCTAssertEqual(-1004, error.code)
                        errorEx.fulfill()
                    case let .success(message):
                        XCTFail("Should not have received message: \(message)")
                    }
                }
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)

            XCTAssertTrue(client.isClosed)
        }
    }

    func testCompleteWhenRemoteCloses() throws {
        try withServer { (server, client) in
            var invalidUTF8Bytes = [0x192, 0x193] as [UInt16]
            let bytes = withUnsafeBytes(of: &invalidUTF8Bytes) { Array($0) }
            let data = Data(bytes: bytes, count: bytes.count)

            let openEx = self.expectation(description: "Should have opened")
            let errorEx = self.expectation(description: "Should have errored")
            let sub = client.sink(
                receiveCompletion: expectFailure(),
                receiveValue: { result in
                    switch result {
                    case .success(.open):
                        XCTAssertTrue(client.isOpen)
                        XCTAssertFalse(client.isClosed)
                        client.send(data)
                        openEx.fulfill()
                    case .failure:
                        errorEx.fulfill()
                    default:
                        break
                    }
                }
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)

            XCTAssertFalse(client.isOpen)
            XCTAssertTrue(client.isClosed)
        }
    }

    func testEchoPush() throws {
        try withEchoServer { (server, client) in
            let message = "hello"
            let completion = self.expectNoError()

            let sub = client.sink(
                receiveCompletion: expectFinished(),
                receiveValue: expectValuesAndThen([
                    .open: { client.send(message, completionHandler: completion) },
                    .text(message): { client.close() }
                ])
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)
        }
    }

    func testEchoBinaryPush() throws {
        try withEchoServer { (server, client) in
            let message = "hello"
            let binary = message.data(using: .utf8)!
            let completion = self.expectNoError()

            let sub = client.sink(
                receiveCompletion: expectFinished(),
                receiveValue: expectValuesAndThen([
                    .open: { client.send(binary, completionHandler: completion) },
                    .text(message): { client.close() }
                ])
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)
        }
    }

    func testJoinLobbyAndEcho() throws {
        let joinPush = "[1,1,\"room:lobby\",\"phx_join\",{}]"
        let echoPush1 = "[1,2,\"room:lobby\",\"echo\",{\"echo\":\"one\"}]"
        let echoPush2 = "[1,3,\"room:lobby\",\"echo\",{\"echo\":\"two\"}]"

        let joinReply = "[1,1,\"room:lobby\",\"phx_reply\",{\"response\":{},\"status\":\"ok\"}]"
        let echoReply1 = "[1,2,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"one\"},\"status\":\"ok\"}]"
        let echoReply2 = "[1,3,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"two\"},\"status\":\"ok\"}]"

        let joinCompletion = self.expectNoError()
        let echo1Completion = self.expectNoError()
        let echo2Completion = self.expectNoError()

        try withReplyServer([joinReply, echoReply1, echoReply2]) { (server, client) in
            let sub = client.sink(
                receiveCompletion: expectFinished(),
                receiveValue: expectValuesAndThen([
                    .open: { client.send(joinPush, completionHandler: joinCompletion) },
                    .text(joinReply): { client.send(echoPush1, completionHandler: echo1Completion) },
                    .text(echoReply1): { client.send(echoPush2, completionHandler: echo2Completion) },
                    .text(echoReply2): { client.close() },
                ])
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 2)
        }
    }

    func testCanSendFromTwoThreadsSimultaneously() throws {
        let queueCount = 8
        let queues = (0..<queueCount).map { DispatchQueue(label: "\($0)") }

        let messageCount = 100
        let sendMessages: (WebSocket) -> Void = { client in
            (0..<messageCount).forEach { messageIndex in
                (0..<queueCount).forEach { queueIndex in
                    queues[queueIndex].async { client.send("\(queueIndex)-\(messageIndex)") }
                }
            }
        }

        let receiveMessageEx = expectation(
            description: "Should have received \(queueCount * messageCount) messages"
        )
        receiveMessageEx.expectedFulfillmentCount = queueCount * messageCount

        try withEchoServer { (server, client) in
            let sub = client.sink(
                receiveCompletion: {_ in },
                receiveValue: { message in
                    switch message {
                    case .success(.open):
                        sendMessages(client)
                    case .success(.text):
                        receiveMessageEx.fulfill()
                    default:
                        XCTFail()
                    }
                }
            )
            defer { sub.cancel() }

            client.connect()
            waitForExpectations(timeout: 10)
            client.close()
        }
    }
}

private extension WebSocketTests {
    func withServer(_ block: (WebSocketServer, WebSocket) throws -> Void) throws {
        let port = ports.removeFirst()
        let server = WebSocketServer(port: port, replyProvider: .reply { nil })
        let client = WebSocket(url: url(port))
        try withExtendedLifetime((server, client)) { server.listen(); try block(server, client) }
    }

    func withEchoServer(_ block: (WebSocketServer, WebSocket) throws -> Void) throws {
        let port = ports.removeFirst()
        let server = WebSocketServer(port: port, replyProvider: .echo)
        let client = WebSocket(url: url(port))
        try withExtendedLifetime((server, client)) { server.listen(); try block(server, client) }
    }

    func withReplyServer(
        _ replies: Array<String?>,
        _ block: (WebSocketServer, WebSocket) throws -> Void
    ) throws {
        let port = ports.removeFirst()
        var replies = replies
        let provider: () -> String? = { return replies.removeFirst() }
        let server = WebSocketServer(port: port, replyProvider: .reply(provider))
        let client = WebSocket(url: url(port))
        try withExtendedLifetime((server, client)) { server.listen(); try block(server, client) }
    }
}

private extension WebSocketTests {
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

    func expectNoError() -> (Error?) -> Void {
        let expectation = self.expectation(description: "Should not have had an error")
        return { error in
            XCTAssertNil(error)
            expectation.fulfill()
        }
    }
}
