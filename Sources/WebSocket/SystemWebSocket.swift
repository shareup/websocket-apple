@preconcurrency import Combine
@preconcurrency import Foundation
@preconcurrency import Network
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

    private let waiter = WebSocketWaiter()
    private nonisolated let subject = PassthroughSubject<Output, Failure>()

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
        waiter.cancelAll()

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
                let _timeout = timeout ?? options.timeoutIntervalForRequest
                try await waiter.open(timeout: _timeout)
            } catch is CancellationError {
                Swift.print("$$$ open(timeout:) CancellationError \(state)")
                doClose(.noStatusReceived)
                throw CancellationError()
            } catch {
                Swift.print("$$$ open(timeout:) \(error) \(state)")
//                doClose(.abnormalClosure, error)
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

            do {
                startClosing(
                    connection: conn,
                    closeCode: closeCode,
                    error: closeCode.error
                )
                let _timeout = timeout ?? options.timeoutIntervalForRequest
                try await waiter.close(timeout: _timeout)
            } catch {
                Swift.print("$$$ close(_:timeout:) connecting or open")
                doClose(closeCode)
                throw error
            }

        case .unopened, .closing, .closed:
            Swift.print("$$$ close(_:timeout:)")
            doClose(closeCode)
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

        Swift.print("$$$ forceClose(_:)")
        doClose(closeCode)
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

        let parameters = try parameters(with: components)
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
        waiter.didOpen()
        onOpen()
        connection.receiveMessage(completion: onReceiveMessage)
    }

    func startClosing(
        connection: NWConnection,
        closeCode: WebSocketCloseCode,
        error: NWError? = nil
    ) {
        state = .closing(closeCode, error)
        subject.send(completion: .finished)
        connection.cancelIfNeeded()
    }

    func doClose(
        _ closeCode: WebSocketCloseCode,
        _ error: Error? = nil
    ) {
        // TODO: Switch to using `state.description`
        os_log(
            "do close connection: state=%{public}s error=%{public}s",
            log: .webSocket,
            type: .debug,
            state.debugDescription,
            String(describing: error)
        )

        let wsError = { (error: Error?) -> WebSocketError? in
            guard let error = error else { return nil }

            if let wsError = error as? WebSocketError {
                return wsError
            } else if let nwError = error as? NWError {
                return .connectionError(nwError)
            } else {
                return .unknown(error as NSError)
            }
        }

        switch state {
        case let .closing(closeCode, .some(err)):
            let _error = wsError(err)
            state = .closed(_error)
            waiter.didClose(error: _error)
            subject.send(completion: .finished)
            onClose((closeCode, _error))

        case let .closing(closeCode, nil):
            let _error = wsError(error)
            state = .closed(_error)
            waiter.didClose(error: _error)
            subject.send(completion: .finished)
            onClose((closeCode, _error))

        case .unopened:
            let _error = wsError(error)
            state = .closed(_error)
            waiter.didClose(error: _error)
            subject.send(completion: .finished)
            onClose((closeCode, _error))

        case let .connecting(conn), let .open(conn):
            let _error = wsError(error)
            state = .closed(_error)
            waiter.didClose(error: _error)
            subject.send(completion: .finished)
            onClose((closeCode, _error))
            conn.forceCancel()

        case .closed:
            waiter.didClose(error: wsError(error))
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
                    Swift.print("$$$ connectionStateUpdateHandler .waiting(\(error))")
                    if let conn = await self.state.connection {
                        await self.startClosing(
                            connection: conn,
                            closeCode: .abnormalClosure,
                            error: error
                        )
                    }

                case .preparing:
                    break

                case .ready:
                    switch state {
                    case let .connecting(conn):
                        await self.openReadyConnection(conn)

                    case .open:
                        Swift.print("$$$ READY-OPEN")
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
                        await self.startClosing(
                            connection: conn,
                            closeCode: .abnormalClosure,
                            error: error
                        )

                    case .unopened, .closing, .closed:
                        break
                    }

                case .cancelled:
                    switch state {
                    case let .connecting(conn), let .open(conn):
                        await self.startClosing(connection: conn, closeCode: .normalClosure)

                    case .unopened, .closing:
                        Swift.print("$$$ connectionStateUpdateHandler .cancelled")
                        await self.doClose(.normalClosure)

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
                case let (_, .some(context), _) where context.isFinal:
                    os_log("receive close", log: .webSocket, type: .debug)
                    await self.doClose(.normalClosure)
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
                startClosing(
                    connection: connection,
                    closeCode: .invalidFramePayloadData,
                    error: .posix(.EBADMSG)
                )
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
            Swift.print("$$$ handleSuccessfulMessage .close")
            doClose(.normalClosure)

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
            startClosing(connection: conn, closeCode: error.closeCode, error: error)

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

        if let conn = state.connection {
            startClosing(connection: conn, closeCode: .unsupportedData, error: error)
        } else {
            let _error: WebSocketError? = error != nil ? .connectionError(error!) : nil
            doClose(.unsupportedData, _error)
        }
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
    case closing(WebSocketCloseCode, NWError?)
    case closed(WebSocketError?)

    var connection: NWConnection? {
        switch self {
        case let .connecting(conn), let .open(conn): return conn
        case .unopened, .closing, .closed: return nil
        }
    }

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
        case .unopened:
            return "unopened"
        case let .connecting(conn):
            return "connecting(\(String(reflecting: conn)))"
        case let .open(conn):
            return "open(\(String(reflecting: conn)))"
        case let .closing(code, error):
            return "closing(\(code), \(error.debugDescription))"
        case let .closed(error):
            return "closed(\(error.debugDescription))"
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
            return .abnormalClosure
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
