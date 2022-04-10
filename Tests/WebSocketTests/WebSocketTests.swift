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
        let isClosed = await client.isClosed
        XCTAssertTrue(isClosed)
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

    func testEchoBinaryPush() async throws {
        let openEx = expectation(description: "Should have opened")
        let (server, client) = await makeEchoServerAndClient { event in
            guard case .open = event else { return }
            openEx.fulfill()
        }
        defer { server.close() }

        wait(for: [openEx], timeout: 0.5)

        try await client.send(.data(Data("hello".utf8)))
        guard case let .string(text) = try await client.receive()
        else { return XCTFail("Should have received text") }

        XCTAssertEqual("hello", text)
    }

    func testJoinLobbyAndEcho() async throws {
        var pushes = [
            "[1,1,\"room:lobby\",\"phx_join\",{}]",
            "[1,2,\"room:lobby\",\"echo\",{\"echo\":\"one\"}]",
            "[1,3,\"room:lobby\",\"echo\",{\"echo\":\"two\"}]",
        ]

        let replies = [
            "[1,1,\"room:lobby\",\"phx_reply\",{\"response\":{},\"status\":\"ok\"}]",
            "[1,2,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"one\"},\"status\":\"ok\"}]",
            "[1,3,\"room:lobby\",\"phx_reply\",{\"response\":{\"echo\":\"two\"},\"status\":\"ok\"}]",
        ]

        let openEx = expectation(description: "Should have opened")

        let (server, client) = await makeReplyServerAndClient(replies) { event in
            guard case .open = event else { return }
            openEx.fulfill()
        }
        defer { server.close() }

        wait(for: [openEx], timeout: 0.5)

        try await client.send(.string(pushes.removeFirst()))
        try await client.send(.string(pushes.removeFirst()))
        try await client.send(.string(pushes.removeFirst()))

        for expected in replies {
            guard case let .string(reply) = try await client.receive() else { return XCTFail() }
            XCTAssertEqual(expected, reply)
        }
    }
}

private extension WebSocketTests {
    func makeServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = try! WebSocketServer(port: port, replyProvider: .reply { nil })
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
//        server.listen()
        return (server, client)
    }

    func makeOfflineServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = try! WebSocketServer(port: 1, replyProvider: .reply { nil })
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
        return (server, client)
    }

    func makeEchoServerAndClient(
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = try! WebSocketServer(port: port, replyProvider: .echo)
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
//        server.listen()
        return (server, client)
    }

    func makeReplyServerAndClient(
        _ replies: [String?],
        _ onStateChange: @escaping (WebSocketEvent) -> Void = { _ in }
    ) async -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        var replies = replies
        let provider: () -> String? = { replies.removeFirst() }
        let server = try! WebSocketServer(port: port, replyProvider: .reply(provider))
        let client = await WebSocket(url: url(port), onStateChange: onStateChange)
//        server.listen()
        return (server, client)
    }
}
