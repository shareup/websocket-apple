@preconcurrency import Combine
import Foundation
import os.log
import Synchronized

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

    private let waiter = WebSocketWaiter()

    private var state: State = .unopened

    private var messageIndex = 0 // Used to identify sent messages

    private nonisolated let subject = PassthroughSubject<Output, Failure>()

    // Deliver messages to the subscribers on a separate queue because it's a bad idea
    // to let the subscribers, who could potentially be doing long-running tasks with the
    // data we send them, block our network queue.
    private let subscriberQueue = DispatchQueue(
        label: "app.shareup.websocket.subjectqueue",
        attributes: [],
        autoreleaseFrequency: .workItem,
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
        state.ws?.cancel()
        subject.send(completion: .finished)
    }

    nonisolated func receive<S: Subscriber>(
        subscriber: S
    ) where S.Input == WebSocketMessage, S.Failure == Never {
        subject
            .receive(on: subscriberQueue)
            .receive(subscriber: subscriber)
    }

    func open(timeout: TimeInterval? = nil) async throws {
        switch state {
        case .unopened, .connecting:
            do {
                let _timeout = timeout ?? options.timeoutIntervalForRequest
                try await waiter.open(timeout: _timeout)

            } catch is CancellationError {
                doClose(closeCode: .cancelled, reason: nil)

            } catch let error as WebSocketError {
                doClose(
                    closeCode: error.closeCode ?? .unknown,
                    reason: error.reason
                )

                throw error
            } catch {
                preconditionFailure("Invalid error: \(String(reflecting: error))")
            }

        case .open:
            return

        case .closed:
            throw WebSocketError(.alreadyClosed, nil)
        }
    }

    func send(_ message: WebSocketMessage) async throws {
        // Mirrors the document behavior of JavaScript's `WebSocket`
        // http://developer.mozilla.org/en-US/docs/Web/API/WebSocket/send
        switch state {
        case let .open(ws):
            messageIndex += 1

            os_log(
                "send: index=%d message=%s",
                log: .webSocket,
                type: .debug,
                messageIndex,
                message.description
            )

            try await ws.send(message.wsMessage)

        case .unopened, .connecting:
            os_log(
                "send message while connecting: %s",
                log: .webSocket,
                type: .error,
                message.description
            )
            throw WebSocketError.sendMessageWhileConnecting

        case .closed:
            os_log(
                "send message while closed: %s",
                log: .webSocket,
                type: .debug,
                message.description
            )
        }
    }

    func close(
        code: WebSocketCloseCode = .normalClosure,
        reason: Data? = nil,
        timeout: TimeInterval? = nil
    ) async throws {
        switch state {
        case .unopened:
            doClose(closeCode: code, reason: reason)

        case .connecting, .open:
            doClose(closeCode: code, reason: reason)
            try await waiter.close(
                timeout: timeout ?? options.timeoutIntervalForRequest
            )

        case .closed:
            doClose(closeCode: code, reason: reason)
        }
    }
}

private extension SystemWebSocket {
    var isUnopened: Bool {
        guard case .unopened = state else { return false }
        return true
    }

    func connect() throws {
        precondition(isUnopened)
        let task = webSocketTask(
            for: url,
            options: options,
            onOpen: { [weak self] in await self?.doOpen() },
            onClose: { [weak self] (closeCode, reason) async -> Void in
                await self?.doClose(closeCode: closeCode, reason: reason)
            }
        )
        state = .connecting(task)
        task.resume()
    }

    func doOpen() {
        switch state {
        case let .connecting(ws):
            os_log("open", log: .webSocket, type: .debug)
            state = .open(ws)
            onOpen()
            waiter.didOpen()
            doReceiveMessage(ws)

        case .unopened:
            os_log("received open before connecting", log: .webSocket, type: .error)
            preconditionFailure("Cannot receive open before trying to connect")

        case .open:
            // Ignore this because there might be multiple consumers
            // waiting on `.open(timeout:)` to return.
            break

        case .closed:
            os_log(
                "trying to open already-closed connection",
                log: .webSocket,
                type: .error
            )
            doClose(closeCode: .alreadyClosed, reason: nil)
        }
    }

    func doReceiveMessage(_ ws: URLSessionWebSocketTask) {
        guard ws.closeCode == .invalid, !Task.isCancelled else { return }

        ws.receive { [weak self] (result: Result<URLSessionWebSocketTask.Message, Error>) in
            guard let self, ws.closeCode == .invalid, !Task.isCancelled else { return }

            switch result {
            case let .success(msg):
                let message = WebSocketMessage(msg)
                os_log(
                    "receive: message=%s",
                    log: .webSocket,
                    type: .debug,
                    message.description
                )
                self.subject.send(message)
                Task { [weak self] in await self?.doReceiveMessage(ws) }

            case let .failure(error):
                Task { [weak self] in
                    await self?.doClose(
                        closeCode: .abnormalClosure,
                        reason: Data(error.localizedDescription.utf8)
                    )
                }
            }
        }
    }

    func doClose(closeCode: WebSocketCloseCode, reason: Data?) {
        switch state {
        case .unopened:
            state = .closed(.init(closeCode, reason))

        case let .connecting(ws), let .open(ws):
            os_log(
                "close: code=%{public}s",
                log: .webSocket,
                type: .debug,
                closeCode.description
            )

            // When the task is not yet closed, this value is `.invalid`.
            if ws.closeCode == .invalid {
                if let code = closeCode.wsCloseCode {
                    ws.cancel(with: code, reason: reason)
                } else {
                    ws.cancel()
                }
            }

            let close = WebSocketClose(closeCode, nil)
            state = .closed(close)
            onClose(close)
            waiter.didClose(code: closeCode, reason: reason)
            subject.send(completion: .finished)

        case .closed:
            break
        }

    }
}

private extension SystemWebSocket {
    enum State: CustomStringConvertible, CustomDebugStringConvertible {
        case unopened
        case connecting(URLSessionWebSocketTask)
        case open(URLSessionWebSocketTask)
        case closed(WebSocketClose)

        var ws: URLSessionWebSocketTask? {
            switch self {
            case let .connecting(ws), let .open(ws):
                return ws

            case .unopened, .closed:
                return nil
            }
        }

        var description: String {
            switch self {
            case .unopened: return "unopened"
            case .connecting: return "connecting"
            case .open: return "open"
            case .closed: return "closed"
            }
        }

        var debugDescription: String {
            switch self {
            case .unopened: return "unopened"
            case let .connecting(ws): return "connecting(\(String(reflecting: ws)))"
            case let .open(ws): return "open(\(String(reflecting: ws)))"
            case let .closed(error): return "closed(\(error.description))"
            }
        }
    }
}
