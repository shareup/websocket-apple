import Combine
import Synchronized
@testable import WebSocket
import XCTest

private var ports = (50000 ... 52000).map { UInt16($0) }

// NOTE: If `WebSocketTests` is not marked as `@MainActor`, calls to
// `wait(for:timeout:)` prevent other asyncronous events from running.
// Using `await waitForExpectations(timeout:handler:)` works properly
// because it's already marked as `@MainActor`.

@MainActor
class SystemWebSocketTests: XCTestCase {
    var subject: PassthroughSubject<WebSocketServerOutput, Error>!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        subject = .init()
    }

    func testCanConnectToAndDisconnectFromServer() async throws {
        let openEx = expectation(description: "Should have opened")
        let closeEx = expectation(description: "Should have closed")
        let (server, client) = try await makeServerAndClient(
            onOpen: { openEx.fulfill() },
            onClose: { close in
                XCTAssertEqual(.normalClosure, close.code)
                XCTAssertNil(close.reason)
                closeEx.fulfill()
            }
        )
        defer { server.shutDown() }

        try await client.open(timeout: 2)
        wait(for: [openEx], timeout: 2)

        let isOpen = await client.isOpen
        XCTAssertTrue(isOpen)

        try await client.close()
        wait(for: [closeEx], timeout: 2)
    }

    func testErrorWhenServerIsUnreachable() async throws {
        let ex = expectation(description: "Should have errored")
        let (server, client) = try await makeOfflineServerAndClient(
            onOpen: { XCTFail("Should not have opened") },
            onClose: { close in
                XCTAssertEqual(.abnormalClosure, close.code)
                XCTAssertNil(close.reason)
                ex.fulfill()
            }
        )
        defer { server.shutDown() }

        waitForExpectations(timeout: 2)

        let isClosed = await client.isClosed
        XCTAssertTrue(isClosed)
    }

    func _testErrorWhenRemoteCloses() async throws {
        let errorEx = expectation(description: "Should have closed")
        let (server, client) = try await makeServerAndClient(
            onClose: { close in
                DispatchQueue.main.async {
                    XCTAssertTrue(
                        .goingAway == close.code || .cancelled == close.code
                    )
                    errorEx.fulfill()
                }
            }
        )
        defer { server.shutDown() }

        // When running tests repeatedly (i.e., on the order of 1000s of times),
        // sometimes the server fails and causes `.open()` to throw.
        do { try await client.open() }
        catch {}

        subject.send(.remoteClose)
        wait(for: [errorEx], timeout: 2)
    }

    func testWebSocketCannotBeOpenedTwice() async throws {
        let closeCount = Locked(0)

        let firstCloseEx = expectation(description: "Should have closed once")
        let secondCloseEx = expectation(description: "Should not have closed more than once")
        secondCloseEx.isInverted = true

        let (server, client) = try await makeServerAndClient(
            onClose: { _ in
                let c = closeCount.access { count -> Int in
                    count += 1
                    return count
                }
                if c == 1 {
                    firstCloseEx.fulfill()
                } else {
                    secondCloseEx.fulfill()
                }
            }
        )
        defer { server.shutDown() }

        try await client.open()

        try await client.close()
        wait(for: [firstCloseEx], timeout: 2)

        do {
            try await client.open()
            XCTFail("Should not have successfully reopened")
        } catch {
            guard let wserror = error as? WebSocketError,
                  case .alreadyClosed = wserror.closeCode
            else { return XCTFail("Received wrong error: \(error)") }
        }

        wait(for: [secondCloseEx], timeout: 0.1)
    }

    func testPushAndReceiveText() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        let sentEx = expectation(description: "Server should have received message")
        let sentSub = server.inputPublisher
            .sink(receiveValue: { message in
                guard case let .text(text) = message
                else { return XCTFail("Should have received text") }
                XCTAssertEqual("hello", text)
                sentEx.fulfill()
            })
        defer { sentSub.cancel() }

        try await client.open()

        let receivedEx = expectation(description: "Should have received message")
        let receivedSub = client.sink { message in
            defer { receivedEx.fulfill() }
            guard case let .text(text) = message
            else { return XCTFail("Should have received text") }
            XCTAssertEqual("hi, to you too!", text)
        }
        defer { receivedSub.cancel() }

        try await client.send(.text("hello"))
        wait(for: [sentEx], timeout: 2)
        subject.send(.message(.text("hi, to you too!")))
        wait(for: [receivedEx], timeout: 2)
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testPushAndReceiveTextWithAsyncPublisher() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        try await client.open()

        try await client.send(.text("hello"))
        subject.send(.message(.text("hi, to you too!")))

        for await message in client.values {
            guard case let .text(text) = message else {
                XCTFail("Should have received text")
                break
            }
            XCTAssertEqual("hi, to you too!", text)
            break
        }
    }

    func testPushAndReceiveData() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        let sentEx = expectation(description: "Server should have received message")
        let sentSub = server.inputPublisher
            .sink(receiveValue: { message in
                guard case let .data(data) = message
                else { return XCTFail("Should have received data") }
                XCTAssertEqual(Data("hello".utf8), data)
                sentEx.fulfill()
            })
        defer { sentSub.cancel() }

        try await client.open()

        let receivedEx = expectation(description: "Should have received message")
        let receivedSub = client.sink { message in
            defer { receivedEx.fulfill() }
            guard case let .data(data) = message
            else { return XCTFail("Should have received data") }
            XCTAssertEqual(Data("hi, to you too!".utf8), data)
        }
        defer { receivedSub.cancel() }

        try await client.send(.data(Data("hello".utf8)))
        wait(for: [sentEx], timeout: 2)
        subject.send(.message(.data(Data("hi, to you too!".utf8))))
        wait(for: [receivedEx], timeout: 2)
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testPushAndReceiveDataWithAsyncPublisher() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        try await client.open()

        try await client.send(.data(Data("hello bytes".utf8)))
        subject.send(.message(.data(Data("howdy".utf8))))

        for await message in client.values {
            guard case let .data(data) = message else {
                XCTFail("Should have received data")
                break
            }
            XCTAssertEqual("howdy", String(data: data, encoding: .utf8))
            break
        }
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testPublisherFinishesOnClose() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        try await client.open()

        let task = Task.detached {
            var count = 1
            repeat {
                await self.subject.send(.message(.text(String(count))))
                count += 1
                try await Task.sleep(nanoseconds: 20 * NSEC_PER_MSEC)
            } while !Task.isCancelled
        }

        var receivedMessages = 0
        for await message in client.values {
            guard let _ = message.stringValue else { return XCTFail() }
            receivedMessages += 1
            if receivedMessages == 3 {
                try await client.close()
            }
        }

        XCTAssertEqual(3, receivedMessages)

        task.cancel()
    }

    @available(iOS 15.0, macOS 12.0, *)
    func testPublisherFinishesOnCloseFromServer() async throws {
        let (server, client) = try await makeServerAndClient()
        defer { server.shutDown() }

        try await client.open()

        let task = Task.detached {
            var count = 1
            repeat {
                await self.subject.send(.message(.text(String(count))))
                count += 1
                try await Task.sleep(nanoseconds: 20 * NSEC_PER_MSEC)
            } while !Task.isCancelled
        }

        var receivedMessages = 0
        for await message in client.values {
            guard let _ = message.stringValue else { return XCTFail() }
            receivedMessages += 1
            if receivedMessages == 3 {
                subject.send(.remoteClose)
            }
        }

        XCTAssertEqual(3, receivedMessages)

        task.cancel()
    }

    func testWrappedSystemWebSocket() async throws {
        let openEx = expectation(description: "Should have opened")
        let closeEx = expectation(description: "Should have closed")
        let (server, client) = try await makeServerAndWrappedClient(
            onOpen: { openEx.fulfill() },
            onClose: { close in
                XCTAssertEqual(.normalClosure, close.code)
                XCTAssertNil(close.reason)
                closeEx.fulfill()
            }
        )
        defer { server.shutDown() }

        let messagesToSendToServer: [WebSocketMessage] = [
            .text("client: one"),
            .data(Data("client: two".utf8)),
            .text("client: three"),
        ]

        let messagesToReceiveFromServer: [WebSocketMessage] = [
            .text("server: one"),
            .data(Data("server: two".utf8)),
            .text("server: three"),
        ]

        var messagesReceivedByServer = 0
        let sentSub = server.inputPublisher
            .sink(receiveValue: { message in
                let i = messagesReceivedByServer
                defer { messagesReceivedByServer += 1 }
                XCTAssertEqual(messagesToSendToServer[i], message)
            })
        defer { sentSub.cancel() }

        // These two lines are redundant, but the goal
        // is to test everything in `WebSocket`.
        try await client.open()
        wait(for: [openEx], timeout: 2)

        // This message has to be sent after the `AsyncStream` is
        // subscribed to below.
        let messageToReceiveFromServer = messagesToReceiveFromServer[0]
        Task.detached {
            await self.subject.send(.message(messageToReceiveFromServer))
        }

        var messagesReceivedByClient = 0
        for await message in client.messages {
            let i = messagesReceivedByClient
            defer { messagesReceivedByClient += 1 }

            XCTAssertEqual(messagesToReceiveFromServer[i], message)
            try await client.send(messagesToSendToServer[i])

            if i < 2 {
                subject.send(.message(messagesToReceiveFromServer[i + 1]))
            } else {
                try await client.close()
            }
        }

        XCTAssertEqual(3, messagesReceivedByClient)
        XCTAssertEqual(3, messagesReceivedByServer)

        wait(for: [closeEx], timeout: 2)
    }
}

private let empty: Empty<WebSocketServerOutput, Error> = Empty(
    completeImmediately: false,
    outputType: WebSocketServerOutput.self,
    failureType: Error.self
)

private extension SystemWebSocketTests {
    func url(_ port: UInt16) -> URL { URL(string: "ws://0.0.0.0:\(port)/socket")! }

    func makeServerAndClient(
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, SystemWebSocket) {
        let port = ports.removeFirst()
        let server = try WebSocketServer(port: port, outputPublisher: subject)
        let client = try! await SystemWebSocket(
            url: url(port),
            options: .init(timeoutIntervalForRequest: 2),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, client)
    }

    func makeOfflineServerAndClient(
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, SystemWebSocket) {
        let port = ports.removeFirst()
        let server = try WebSocketServer(port: 52001, outputPublisher: empty)
        let client = try! await SystemWebSocket(
            url: url(port),
            options: .init(timeoutIntervalForRequest: 2),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, client)
    }

    func makeServerAndWrappedClient(
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, WebSocket) {
        let port = ports.removeFirst()
        let server = try WebSocketServer(port: port, outputPublisher: subject)
        let client = try! await SystemWebSocket(
            url: url(port),
            options: .init(timeoutIntervalForRequest: 2),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, try! await .system(client))
    }
}
