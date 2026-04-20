import AsyncExtensions
import Combine
import NIO
import NIOWebSocket
import Synchronized
@testable import WebSocket
import XCTest

class SystemWebSocketTests: XCTestCase {
    var subject: PassthroughSubject<WebSocketServerOutput, Error>!

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

        try await client.open()
        await fulfillment(of: [openEx], timeout: 2)

        let isOpen = await client.isOpen
        XCTAssertTrue(isOpen)

        try await client.close()
        await fulfillment(of: [closeEx], timeout: 2)
    }

    func testErrorWhenServerIsUnreachable() async throws {
        let ex = expectation(description: "Should have errored")
        let (server, client) = try await makeOfflineServerAndClient(
            onOpen: { XCTFail("Should not have opened") },
            onClose: { close in
                XCTAssertEqual(.abnormalClosure, close.code)
                XCTAssertNotNil(close.reason)
                ex.fulfill()
            }
        )
        defer { server.shutDown() }

        await fulfillment(of: [ex], timeout: 2)

        let isClosed = await client.isClosed
        XCTAssertTrue(isClosed)
    }

    func testOpenCancellationThrowsCancellationError() async throws {
        let server = try HangingServer()
        defer { server.shutDown() }

        let client = try await SystemWebSocket(
            request: request(server.port),
            options: .init(timeoutIntervalForRequest: 5)
        )

        let openTask = Task {
            try await client.open()
        }

        try await Task.sleep(nanoseconds: 50 * NSEC_PER_MSEC)
        openTask.cancel()

        switch await openTask.result {
        case .success:
            XCTFail("Expected `open()` to throw `CancellationError`")

        case let .failure(error):
            XCTAssertTrue(
                error is CancellationError,
                "Received wrong error: \(String(reflecting: error))"
            )
        }
    }

    func testOpenThrowsConnectionErrorWhenServerIsUnreachable() async throws {
        let (server, client) = try await makeOfflineServerAndClient(
            timeoutIntervalForRequest: 0.2
        )
        defer { server.shutDown() }

        do {
            try await client.open()
            XCTFail("Should not have opened")
        } catch is TimeoutError {
            XCTFail("Should surface the connection failure instead of timing out")
        } catch let error as WebSocketError {
            XCTAssertEqual(.abnormalClosure, error.closeCode)
        } catch {
            XCTFail("Received wrong error: \(error)")
        }
    }

    func _testErrorWhenRemoteCloses() async throws {
        let errorEx = expectation(description: "Should have closed")
        let (server, client) = try await makeServerAndClient(
            onClose: { close in
                DispatchQueue.main.async {
                    XCTAssertTrue(
                        close.code == .goingAway || close.code == .cancelled
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
        await fulfillment(of: [errorEx], timeout: 2)
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
        await fulfillment(of: [firstCloseEx], timeout: 2)

        do {
            try await client.open()
            XCTFail("Should not have successfully reopened")
        } catch {
            guard let wserror = error as? WebSocketError,
                  case .alreadyClosed = wserror.closeCode
            else { return XCTFail("Received wrong error: \(error)") }
        }

        await fulfillment(of: [secondCloseEx], timeout: 0.1)
    }

    func testDelegateDoesNotReorderOpenAndCloseCallbacks() async throws {
        let delegate = Delegate()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1/socket")!)
        let openStarted = AsyncThrowingFuture<Void>(timeout: 2)
        let allowOpenToFinish = AsyncThrowingFuture<Void>(timeout: 2)
        let records = Locked([String]())

        delegate.set(
            onOpen: {
                records.access { $0.append("open-started") }
                openStarted.resolve()
                do { try await allowOpenToFinish.value }
                catch { XCTFail() }
                records.access { $0.append("open-finished") }
            },
            onClose: { _, _ in
                records.access { $0.append("close") }
            },
            for: ObjectIdentifier(task)
        )

        delegate.urlSession(session, webSocketTask: task, didOpenWithProtocol: nil)
        try await openStarted.value

        delegate.urlSession(
            session,
            webSocketTask: task,
            didCloseWith: .goingAway,
            reason: nil
        )

        try await Task.sleep(nanoseconds: 10 * NSEC_PER_MSEC)
        let eventsBeforeOpenFinishes = records.access { $0 }
        XCTAssertEqual(["open-started"], eventsBeforeOpenFinishes)

        allowOpenToFinish.resolve()
        try await Task.sleep(nanoseconds: 10 * NSEC_PER_MSEC)
        let eventsAfterOpenFinishes = records.access { $0 }
        XCTAssertEqual(
            ["open-started", "open-finished", "close"],
            eventsAfterOpenFinishes
        )
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
        await fulfillment(of: [sentEx], timeout: 2)
        subject.send(.message(.text("hi, to you too!")))
        await fulfillment(of: [receivedEx], timeout: 2)
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
        await fulfillment(of: [sentEx], timeout: 2)
        subject.send(.message(.data(Data("hi, to you too!".utf8))))
        await fulfillment(of: [receivedEx], timeout: 2)
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
                self.subject.send(.message(.text(String(count))))
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
                self.subject.send(.message(.text(String(count))))
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
        await fulfillment(of: [openEx], timeout: 2)

        // This message has to be sent after the `AsyncStream` is
        // subscribed to below.
        let messageToReceiveFromServer = messagesToReceiveFromServer[0]
        Task.detached {
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            self.subject.send(.message(messageToReceiveFromServer))
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

        await fulfillment(of: [closeEx], timeout: 2)

        XCTAssertEqual(3, messagesReceivedByClient)
        XCTAssertEqual(3, messagesReceivedByServer)
    }

    func testRemoteCloseReasonIsPassedToOnClose() async throws {
        let closeEx = expectation(description: "Should expose the close reason")
        let reason = Data("server said goodbye".utf8)

        let (server, client) = try await makeServerAndClient(
            onClose: { close in
                XCTAssertEqual(.goingAway, close.code)
                XCTAssertEqual(reason, close.reason)
                closeEx.fulfill()
            }
        )
        defer { server.shutDown() }

        try await client.open()
        subject.send(.remoteCloseWithReason(.goingAway, reason))
        await fulfillment(of: [closeEx], timeout: 2)
    }
}

private let empty: Empty<WebSocketServerOutput, Error> = Empty(
    completeImmediately: false,
    outputType: WebSocketServerOutput.self,
    failureType: Error.self
)

private extension SystemWebSocketTests {
    func request(_ port: Int) -> URLRequest {
        URLRequest(
            url: URL(string: "ws://127.0.0.1:\(port)/socket")!
        )
    }

    func makeServerAndClient(
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, SystemWebSocket) {
        let server = try WebSocketServer(outputPublisher: subject)
        let client = try! await SystemWebSocket(
            request: request(server.port),
            options: .init(timeoutIntervalForRequest: 2),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, client)
    }

    func makeOfflineServerAndClient(
        timeoutIntervalForRequest: TimeInterval = 2,
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, SystemWebSocket) {
        let server = try WebSocketServer(outputPublisher: empty)
        let client = try! await SystemWebSocket(
            request: request(19),
            options: .init(timeoutIntervalForRequest: timeoutIntervalForRequest),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, client)
    }

    func makeServerAndWrappedClient(
        onOpen: @escaping @Sendable () -> Void = {},
        onClose: @escaping @Sendable (WebSocketClose) -> Void = { _ in }
    ) async throws -> (WebSocketServer, WebSocket) {
        let server = try WebSocketServer(outputPublisher: subject)
        let client = try! await SystemWebSocket(
            request: request(server.port),
            options: .init(timeoutIntervalForRequest: 2),
            onOpen: onOpen,
            onClose: onClose
        )
        return (server, try! await .system(client))
    }
}

private final class HangingServer {
    var port: Int { channel!.localAddress!.port! }

    private let eventLoopGroup: EventLoopGroup
    private var channel: Channel?

    init() throws {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        channel = try ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    func shutDown() {
        try? channel?.close(mode: .all).wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }
}
