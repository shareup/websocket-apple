import Combine
@testable import WebSocket
import XCTest

private var ports = (50000 ... 52000).map { UInt16($0) }

// NOTE: If `WebSocketTests` is not marked as `@MainActor`, calls to
// `wait(for:timeout:)` prevent other asyncronous events from running.
// Using `await waitForExpectations(timeout:handler:)` works properly
// because it's already marked as `@MainActor`.

@MainActor
class WebSocketTests: XCTestCase {
    func url(_ port: UInt16) -> URL { URL(string: "ws://0.0.0.0:\(port)/socket")! }

    func testCanConnectToAndDisconnectFromServer() async throws {
        let openEx = expectation(description: "Should have opened")
        let closeEx = expectation(description: "Should have closed")
        let (server, client) = await makeServerAndClient { event in
            switch event {
            case .open:
                openEx.fulfill()

            case let .close(closeCode, _):
                XCTAssertEqual(.normalClosure, closeCode)
                closeEx.fulfill()

            case let .error(error):
                XCTFail("Should not have received error: \(String(describing: error))")
            }
        }
        defer { server.close() }

        wait(for: [openEx], timeout: 0.5)

        let isOpen = await client.isOpen
        XCTAssertTrue(isOpen)

        await client.close(.normalClosure)
        wait(for: [closeEx], timeout: 0.5)
    }

//    func testCustom() async throws {
//        let (server, client) = await makeServerAndClient()
//
//        try await Task.sleep(nanoseconds: NSEC_PER_SEC * 10000)
//        server.close()
//    }

    func testErrorWhenServerIsUnreachable() async throws {
        let ex = expectation(description: "Should have errored")
        let (server, client) = await makeOfflineServerAndClient { event in
            guard case let .error(error) = event else {
                return XCTFail("Should not have received \(event)")
            }
            XCTAssertEqual(-1004, error?.code)
            ex.fulfill()
        }
        defer { server.close() }

        waitForExpectations(timeout: 0.5)

        let isClosed = await client.isClosed
        XCTAssertTrue(isClosed)
    }

    func testErrorWhenRemoteCloses() async throws {
        var invalidUTF8Bytes = [0x192, 0x193] as [UInt16]
        let bytes = withUnsafeBytes(of: &invalidUTF8Bytes) { Array($0) }
        let data = Data(bytes: bytes, count: bytes.count)

        let openEx = expectation(description: "Should have opened")
        let errorEx = expectation(description: "Should have errored")

        let (server, client) = await makeServerAndClient { event in
            switch event {
            case .open:
                openEx.fulfill()

            case .close:
                Swift.print("$$$ CLOSED")
                XCTFail("Should not have closed")

            case let .error(error):
                Swift.print("$$$ ERROR: \(String(describing: error))")
                errorEx.fulfill()
            }
        }
        defer { server.close() }

        wait(for: [openEx], timeout: 0.5)
        let isOpen = await client.isOpen
        XCTAssertTrue(isOpen)

        try await client.send(.data(data))
        wait(for: [errorEx], timeout: 0.5)
//        let isClosed = await client.isClosed
//        XCTAssertTrue(isClosed)
    }

    func testEchoPush() async throws {
        let openEx = expectation(description: "Should have opened")
        let (server, client) = await makeEchoServerAndClient { event in
            guard case .open = event else { return }
            openEx.fulfill()
        }
        defer { server.close() }

        wait(for: [openEx], timeout: 0.5)

        try await client.send(.string("hello"))
        guard case let .string(text) = try await client.receive()
        else { return XCTFail("Should have received text") }

        XCTAssertEqual("hello", text)
    }

//    func testEchoPush() throws {
//        try withEchoServer { _, client in
//            let message = "hello"
//            let completion = self.expectNoError()
//
//            let sub = client.sink(
//                receiveCompletion: expectFinished(),
//                receiveValue: expectValuesAndThen([
//                    .open: { client.send(message, completionHandler: completion) },
//                    .text(message): { client.close() },
//                ])
//            )
//            defer { sub.cancel() }
//
//            client.connect()
//            waitForExpectations(timeout: 2)
//        }
//    }
//
//    func testEchoBinaryPush() throws {
//        try withEchoServer { _, client in
//            let message = "hello"
//            let data = message.data(using: .utf8)!
//            let completion = self.expectNoError()
//
//            let sub = client.sink(
//                receiveCompletion: expectFinished(),
//                receiveValue: expectValuesAndThen([
//                    .open: { client.send(data, completionHandler: completion) },
//                    .text(message): { client.close() },
//                ])
//            )
//            defer { sub.cancel() }
//
//            client.connect()
//            waitForExpectations(timeout: 2)
//        }
//    }
//
//    func testJoinLobbyAndEcho() throws {
//        let joinPush = "[1,1,\"room:lobby\",\"phx_join\",{}]"
//        let echoPush1 = "[1,2,\"room:lobby\",\"echo\",{\"echo\":\"one\"}]"
//        let echoPush2 = "[1,3,\"room:lobby\",\"echo\",{\"echo\":\"two\"}]"
//
//        let joinReply = "[1,1,\"room:lobby\",\"phx_reply\",{\"response\":{},\"status\":\"ok\"}]"
//        let echoReply1 =
//            "[1,2,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"one\"},\"status\":\"ok\"}]"
//        let echoReply2 =
//            "[1,3,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"two\"},\"status\":\"ok\"}]"
//
//        let joinCompletion = expectNoError()
//        let echo1Completion = expectNoError()
//        let echo2Completion = expectNoError()
//
//        try withReplyServer([joinReply, echoReply1, echoReply2]) { _, client in
//            let sub = client.sink(
//                receiveCompletion: expectFinished(),
//                receiveValue: expectValuesAndThen([
//                    .open: { client.send(joinPush, completionHandler: joinCompletion) },
//                    .text(joinReply): { client.send(echoPush1, completionHandler: echo1Completion)
//                    },
//                    .text(echoReply1): { client.send(echoPush2, completionHandler: echo2Completion)
//                    },
//                    .text(echoReply2): { client.close() },
//                ])
//            )
//            defer { sub.cancel() }
//
//            client.connect()
//            waitForExpectations(timeout: 2)
//        }
//    }
//
//    func testCanSendFromTwoThreadsSimultaneously() throws {
//        let queueCount = 8
//        let queues = (0 ..< queueCount).map { DispatchQueue(label: "\($0)") }
//
//        let messageCount = 100
//        let sendMessages: (WebSocket) -> Void = { client in
//            (0 ..< messageCount).forEach { messageIndex in
//                (0 ..< queueCount).forEach { queueIndex in
//                    queues[queueIndex].async { client.send("\(queueIndex)-\(messageIndex)") }
//                }
//            }
//        }
//
//        let receiveMessageEx = expectation(
//            description: "Should have received \(queueCount * messageCount) messages"
//        )
//        receiveMessageEx.expectedFulfillmentCount = queueCount * messageCount
//
//        try withEchoServer { _, client in
//            let sub = client.sink(
//                receiveCompletion: { _ in },
//                receiveValue: { message in
//                    switch message {
//                    case .success(.open):
//                        sendMessages(client)
//                    case .success(.text):
//                        receiveMessageEx.fulfill()
//                    default:
//                        XCTFail()
//                    }
//                }
//            )
//            defer { sub.cancel() }
//
//            client.connect()
//            waitForExpectations(timeout: 10)
//            client.close()
//        }
//    }
}

private extension WebSocketTests {
    func makeServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = WebSocketServer(port: port, replyProvider: .reply { nil })
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
        server.listen()
        return (server, client)
    }

    func makeOfflineServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = WebSocketServer(port: port, replyProvider: .reply { nil })
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
        return (server, client)
    }

    func makeEchoServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = WebSocketServer(port: port, replyProvider: .echo)
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
        server.listen()
        return (server, client)
    }

    func makeReplyServerAndClient(
        _ replies: [String?],
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        var replies = replies
        let provider: () -> String? = { replies.removeFirst() }
        let server = WebSocketServer(port: port, replyProvider: .reply(provider))
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
        server.listen()
        return (server, client)
    }
}
