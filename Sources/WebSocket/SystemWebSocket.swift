import Combine
import Foundation
import Network
import os.log

final actor SystemWebSocket: Publisher {
    typealias Output = WebSocketMessage
    typealias Failure = Never

    var isOpen: Bool { get async {
        guard case .open = state else { return false }
        return true
    } }

    var isClosed: Bool { get async {
        guard case .closed = state else { return false }
        return true
    } }

    nonisolated let url: URL
    nonisolated let options: WebSocketOptions
    nonisolated let onOpen: WebSocketOnOpen
    nonisolated let onClose: WebSocketOnClose

    private var state: WebSocketState = .unopened

    private var messageIndex = 0 // Used to identify sent messages

    private let subject = PassthroughSubject<Output, Failure>()

    private let webSocketQueue: DispatchQueue = .init(
        label: "app.shareup.websocket.websocketqueue",
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: .global(qos: .default)
    )

    // Deliver messages to the subscribers on a separate queue because it's a bad idea
    // to let the subscribers, who could potentially be doing long-running tasks with the
    // data we send them, block our network queue.
    private let subscriberQueue = DispatchQueue(
        label: "app.shareup.websocket.subjectqueue",
        attributes: [],
        target: DispatchQueue.global(qos: .default)
    )

    init(
        url: URL,
        options: WebSocketOptions = .init(),
        onOpen: @escaping WebSocketOnOpen = {},
        onClose: @escaping WebSocketOnClose = { _ in }
    ) async throws {
        self.url = url
        self.options = options
        self.onOpen = onOpen
        self.onClose = onClose
        try connect()
    }

    deinit {
        switch state {
        case let .connecting(connection), let .open(connection):
            subject.send(completion: .finished)
            connection.forceCancel()
        default:
            break
        }
    }

    nonisolated func receive<S: Subscriber>(subscriber: S)
        where S.Input == WebSocketMessage, S.Failure == Never
    {
        subject
            .receive(on: subscriberQueue)
            .receive(subscriber: subscriber)
    }

    func open(timeout: TimeInterval? = nil) async throws {
        switch state {
        case .open:
            return

        case .closing, .closed:
            throw WebSocketError.openAfterConnectionClosed

        case .unopened, .connecting:
            do {
                try await withThrowingTaskGroup(
                    of: Void
                        .self
                ) { (group: inout ThrowingTaskGroup<Void, Error>) in
                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self = self else { return }
                        let _timeout = UInt64(timeout ?? self.options.timeoutIntervalForRequest)
                        try await Task.sleep(nanoseconds: _timeout * NSEC_PER_SEC)
                        throw CancellationError()
                    }

                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self = self else { return }
                        while await !self.isOpen {
                            try await Task.sleep(nanoseconds: 10 * NSEC_PER_MSEC)
                        }
                    }

                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                doClose()
                throw error
            }
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        // Mirrors the document behavior of JavaScript's `WebSocket`
        // http://developer.mozilla.org/en-US/docs/Web/API/WebSocket/send
        switch state {
        case let .open(connection):
            messageIndex += 1

            os_log(
                "send: index=%d message=%s",
                log: .webSocket,
                type: .debug,
                messageIndex,
                message.debugDescription
            )

            let context = NWConnection.ContentContext(
                identifier: String(messageIndex),
                metadata: [message.metadata]
            )

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: message.contentAsData,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { (error: NWError?) in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                )
            }

        case .unopened, .connecting:
            os_log(
                "send message while connecting: %s",
                log: .webSocket,
                type: .error,
                message.debugDescription
            )
            throw WebSocketError.sendMessageWhileConnecting

        case .closing, .closed:
            os_log(
                "send message while closed: %s",
                log: .webSocket,
                type: .debug,
                message.debugDescription
            )
        }
    }

    func close(
        _ closeCode: WebSocketCloseCode = .normalClosure,
        timeout: TimeInterval? = nil
    ) async throws {
        switch state {
        case let .connecting(conn), let .open(conn):
            os_log(
                "close connection: code=%d state=%{public}s",
                log: .webSocket,
                type: .debug,
                closeCode.rawValue,
                state.description
            )

            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(
                    content: nil,
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { (error: Error?) in
                        if let error = error {
                            cont.resume(throwing: error)
                        } else {
                            cont.resume()
                        }
                    }
                )
            }

            startClosing(connection: conn, error: closeCode.error)

            do {
                try await withThrowingTaskGroup(
                    of: Void
                        .self
                ) { (group: inout ThrowingTaskGroup<Void, Error>) in
                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self = self else { return }
                        let _timeout = UInt64(timeout ?? self.options.timeoutIntervalForRequest)
                        try await Task.sleep(nanoseconds: _timeout * NSEC_PER_SEC)
                        throw CancellationError()
                    }

                    _ = group.addTaskUnlessCancelled { [weak self] in
                        guard let self = self else { return }
                        while await !self.isClosed {
                            try await Task.sleep(nanoseconds: 10 * NSEC_PER_MSEC)
                        }
                    }

                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                doClose()
                throw error
            }

        case .unopened, .closing, .closed:
            doClose()
        }
    }

    func forceClose(_ closeCode: WebSocketCloseCode) {
        os_log(
            "force close connection: code=%d state=%{public}s",
            log: .webSocket,
            type: .debug,
            closeCode.rawValue,
            state.description
        )

        doClose()
    }
}

private extension SystemWebSocket {
    var isUnopened: Bool {
        switch state {
        case .unopened: return true
        default: return false
        }
    }

    func setState(_ state: WebSocketState) async {
        self.state = state
    }

    func connect() throws {
        precondition(isUnopened)

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw WebSocketError.invalidURL(url)
        }

        let parameters = try self.parameters(with: components)
        let connection = NWConnection(to: .url(url), using: parameters)
        state = .connecting(connection)
        connection.stateUpdateHandler = connectionStateUpdateHandler
        connection.start(queue: webSocketQueue)
    }

    func openReadyConnection(_ connection: NWConnection) {
        os_log(
            "open connection: connection_state=%{public}s",
            log: .webSocket,
            type: .debug,
            connection.state.debugDescription
        )

        state = .open(connection)
        onOpen()
        connection.receiveMessage(completion: onReceiveMessage)
    }

    func startClosing(connection: NWConnection, error: NWError? = nil) {
        state = .closing(error)
        subject.send(completion: .finished)
        connection.cancel()
    }

    func doClose() {
        // TODO: Switch to using `state.description`
        os_log(
            "do close connection: state=%{public}s",
            log: .webSocket,
            type: .debug,
            state.debugDescription
        )

        switch state {
        case .closing(nil):
            state = .closed(nil)
            subject.send(completion: .finished)
            onClose(normalClosure)

        case let .closing(.some(err)):
            state = .closed(.connectionError(err))
            subject.send(completion: .finished)
            onClose(closureWithError(err))

        case .unopened:
            state = .closed(nil)
            subject.send(completion: .finished)
            onClose(abnormalClosure)

        case let .connecting(conn), let .open(conn):
            state = .closed(nil)
            subject.send(completion: .finished)
            onClose(abnormalClosure)
            conn.forceCancel()

        case .closed:
            // `PassthroughSubject` only sends completions once.
            subject.send(completion: .finished)
        }
    }

    func doCloseWithError(_ error: WebSocketError) {
        // TODO: Switch to using `state.description`
        os_log(
            "do close connection: state=%{public}s error=%{public}s",
            log: .webSocket,
            type: .debug,
            state.debugDescription,
            String(describing: error)
        )

        switch state {
        case let .closing(.some(err)):
            state = .closed(.connectionError(err))
            subject.send(completion: .finished)
            onClose(closureWithError(err))

        case .closing(nil):
            state = .closed(error)
            subject.send(completion: .finished)
            onClose(closureWithError(error))

        case .unopened:
            state = .closed(error)
            subject.send(completion: .finished)
            onClose(closureWithError(error))

        case let .connecting(conn), let .open(conn):
            state = .closed(nil)
            subject.send(completion: .finished)
            onClose(closureWithError(error))
            conn.forceCancel()

        case .closed:
            // `PassthroughSubject` only sends completions once.
            subject.send(completion: .finished)
        }
    }
}

private extension SystemWebSocket {
    func host(with urlComponents: URLComponents) throws -> NWEndpoint.Host {
        guard let host = urlComponents.host else {
            throw WebSocketError.invalidURLComponents(urlComponents)
        }
        return NWEndpoint.Host(host)
    }

    func port(with urlComponents: URLComponents) throws -> NWEndpoint.Port {
        if let raw = urlComponents.port, let port = NWEndpoint.Port(rawValue: UInt16(raw)) {
            return port
        } else if urlComponents.scheme == "ws" {
            return NWEndpoint.Port.http
        } else if urlComponents.scheme == "wss" {
            return NWEndpoint.Port.https
        } else {
            throw WebSocketError.invalidURLComponents(urlComponents)
        }
    }

    func parameters(with urlComponents: URLComponents) throws -> NWParameters {
        let parameters: NWParameters
        switch urlComponents.scheme {
        case "ws":
            parameters = .tcp
        case "wss":
            parameters = .tls
        default:
            throw WebSocketError.invalidURLComponents(urlComponents)
        }

        let webSocketOptions = NWProtocolWebSocket.Options()
        webSocketOptions.maximumMessageSize = options.maximumMessageSize
        webSocketOptions.autoReplyPing = true

        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        return parameters
    }
}

private extension SystemWebSocket {
    var connectionStateUpdateHandler: (NWConnection.State) -> Void {
        { [weak self] (connectionState: NWConnection.State) in
            Task { [weak self] in
                guard let self = self else { return }

                let state = await self.state

                // TODO: Switch to using `state.description`
                os_log(
                    "connection state update: connection_state=%{public}s state=%{public}s",
                    log: .webSocket,
                    type: .debug,
                    connectionState.debugDescription,
                    state.debugDescription
                )

                switch connectionState {
                case .setup:
                    break

                case let .waiting(error):
                    await self.doCloseWithError(.connectionError(error))

                case .preparing:
                    break

                case .ready:
                    switch state {
                    case let .connecting(conn):
                        await self.openReadyConnection(conn)

                    case .open:
                        // TODO: Handle betterPathUpdate here?
                        break

                    case .unopened, .closing, .closed:
                        // TODO: Switch to using `state.description`
                        os_log(
                            "unexpected connection ready: state=%{public}s",
                            log: .webSocket,
                            type: .error,
                            state.debugDescription
                        )
                    }

                case let .failed(error):
                    switch state {
                    case let .connecting(conn), let .open(conn):
                        await self.startClosing(connection: conn, error: error)

                    case .unopened, .closing, .closed:
                        break
                    }

                case .cancelled:
                    switch state {
                    case let .connecting(conn), let .open(conn):
                        await self.startClosing(connection: conn)

                    case .unopened, .closing:
                        await self.doClose()

                    case .closed:
                        break
                    }

                @unknown default:
                    assertionFailure("Unknown state '\(state)'")
                }
            }
        }
    }

    var onReceiveMessage: (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void {
        { [weak self] data, context, isMessageComplete, error in
            guard let self = self else { return }
            guard isMessageComplete else { return }

            Task {
                switch (data, context, error) {
                case let (.some(data), .some(context), .none):
                    await self.handleSuccessfulMessage(data: data, context: context)
                case let (.none, _, .some(error)):
                    await self.handleMessageWithError(error)
                default:
                    await self.handleUnknownMessage(data: data, context: context, error: error)
                }
            }
        }
    }

    func handleSuccessfulMessage(data: Data, context: NWConnection.ContentContext) {
        guard case let .open(connection) = state else { return }

        switch context.websocketMessageType {
        case .binary:
            os_log(
                "receive binary: size=%d",
                log: .webSocket,
                type: .debug,
                data.count
            )
            subject.send(.data(data))

        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                startClosing(connection: connection, error: .posix(.EBADMSG))
                return
            }
            os_log(
                "receive text: content=%s",
                log: .webSocket,
                type: .debug,
                text
            )
            subject.send(.text(text))

        case .close:
            doClose()

        case .pong:
            // TODO: Handle pongs at some point
            break

        default:
            let messageType = String(describing: context.websocketMessageType)
            assertionFailure("Unexpected message type: \(messageType)")
        }

        connection.receiveMessage(completion: onReceiveMessage)
    }

    func handleMessageWithError(_ error: NWError) {
        switch state {
        case let .connecting(conn), let .open(conn):
            startClosing(connection: conn, error: error)

        case .unopened, .closing, .closed:
            // TODO: Should we call `doClose()` here, instead?
            break
        }
    }

    func handleUnknownMessage(
        data: Data?,
        context: NWConnection.ContentContext?,
        error: NWError?
    ) {
        func describeInputs() -> String {
            String(describing: String(data: data ?? Data(), encoding: .utf8)) + " " +
                String(describing: context) + " " + String(describing: error)
        }

        // TODO: Switch to using `state.description`
        os_log(
            "unknown message: state=%{public}s message=%s",
            log: .webSocket,
            type: .error,
            state.debugDescription,
            describeInputs()
        )

        doCloseWithError(WebSocketError.receiveUnknownMessageType)
    }
}

private extension WebSocketMessage {
    var metadata: NWProtocolWebSocket.Metadata {
        switch self {
        case .data: return .init(opcode: .binary)
        case .text: return .init(opcode: .text)
        }
    }

    var contentAsData: Data {
        switch self {
        case let .data(data): return data
        case let .text(text): return Data(text.utf8)
        }
    }
}

private enum WebSocketState: CustomStringConvertible, CustomDebugStringConvertible {
    case unopened
    case connecting(NWConnection)
    case open(NWConnection)
    case closing(NWError?)
    case closed(WebSocketError?)

    var description: String {
        switch self {
        case .unopened: return "unopened"
        case .connecting: return "connecting"
        case .open: return "open"
        case .closing: return "closing"
        case .closed: return "closed"
        }
    }

    var debugDescription: String {
        switch self {
        case .unopened: return "unopened"
        case let .connecting(conn): return "connecting(\(String(reflecting: conn)))"
        case let .open(conn): return "open(\(String(reflecting: conn)))"
        case let .closing(error): return "closing(\(error.debugDescription))"
        case let .closed(error): return "closed(\(error.debugDescription))"
        }
    }
}

private extension NWConnection.ContentContext {
    var webSocketMetadata: NWProtocolWebSocket.Metadata? {
        let definition = NWProtocolWebSocket.definition
        return protocolMetadata(definition: definition) as? NWProtocolWebSocket.Metadata
    }

    var websocketMessageType: NWProtocolWebSocket.Opcode? {
        webSocketMetadata?.opcode
    }
}

private extension NWError {
    var shouldCloseConnectionWhileConnectingOrOpen: Bool {
        switch self {
        case .posix(.ECANCELED), .posix(.ENOTCONN):
            return false
        default:
            print("Unhandled error in '\(#function)': \(debugDescription)")
            return true
        }
    }

    var closeCode: WebSocketCloseCode {
        switch self {
        case .posix(.ECANCELED):
            return .normalClosure
        default:
            print("Unhandled error in '\(#function)': \(debugDescription)")
            return .normalClosure
        }
    }
}

private extension NWConnection.State {
    var debugDescription: String {
        switch self {
        case .setup: return "setup"
        case let .waiting(error): return "waiting(\(String(reflecting: error)))"
        case .preparing: return "preparing"
        case .ready: return "ready"
        case let .failed(error): return "failed(\(String(reflecting: error)))"
        case .cancelled: return "cancelled"
        @unknown default: return "unknown"
        }
    }
}

private extension Optional where Wrapped == NWError {
    var debugDescription: String {
        guard case let .some(error) = self else { return "" }
        return String(reflecting: error)
    }
}
