import Combine
import Foundation
import os.log
import Synchronized

final actor WebSocket {
    let url: URL
    let options: WebSocketOptions

    var isOpen: Bool {
         get async {
             guard case .open = state else { return false }
             return true
        }
    }

    var isClosed: Bool { get async { await !isOpen } }

    private var onStateChange: (WebSocketEvent) -> Void
    private var state: WebSocketState = .unopened

    init(
        url: URL,
        options: WebSocketOptions = .init(),
        onStateChange: @escaping (WebSocketEvent) -> Void
    ) async {
        self.url = url
        self.options = options
        self.onStateChange = onStateChange
        connect()
    }

    func setOnStateChange(_ block: @escaping (WebSocketEvent) -> Void) async {
        onStateChange = block
    }

    func close(_ code: WebSocketCloseCode) async {
        os_log(
            "close: oldstate=%{public}@ code=%lld",
            log: .webSocket,
            type: .debug,
            state.description,
            code.rawValue
        )

        switch state {
        case let .connecting(session, task, _), let .open(session, task, _):
            state = .closed(code.urlSessionCloseCode, nil)
            onStateChange(.close(code, nil))
            task.cancel(with: code.urlSessionCloseCode, reason: nil)
            session.finishTasksAndInvalidate()

        case .unopened, .closing, .closed:
            break
        }
    }

    func send(_ message: URLSessionWebSocketTask.Message) async throws {
        // Mirrors the document behavior of JavaScript's `WebSocket`
        // http://developer.mozilla.org/en-US/docs/Web/API/WebSocket/send
        switch state {
        case let .open(_, task, _):
            os_log("send: %s", log: .webSocket, type: .debug, message.debugDescription)
            try await task.send(message)

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

    func receive() async throws -> URLSessionWebSocketTask.Message {
        switch state {
        case let .open(_, task, _):
            let message = try await task.receive()
            os_log("receive: %s", log: .webSocket, type: .debug, message.debugDescription)
            return message

        case .unopened, .connecting, .closing, .closed:
            os_log(
                "receive in incorrect state: %s",
                log: .webSocket,
                type: .error,
                state.description
            )
            throw WebSocketError.receiveMessageWhenNotOpen
        }
    }
}

private extension WebSocket {
    func setState(_ state: WebSocketState) async {
        self.state = state
    }

    func connect() {
        os_log(
            "connect: oldstate=%{public}@",
            log: .webSocket,
            type: .debug,
            state.description
        )

        switch state {
        case .closed, .unopened:
            let delegate = WebSocketDelegate(onStateChange: onDelegateEvent)

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = options.timeoutIntervalForRequest
            config.timeoutIntervalForResource = options.timeoutIntervalForResource

            let session = URLSession(
                configuration: config,
                delegate: delegate,
                delegateQueue: nil
            )

            let task = session.webSocketTask(with: url)
            task.maximumMessageSize = options.maximumMessageSize
            state = .connecting(session, task, delegate)

            task.resume()

        default:
            break
        }
    }

    var onDelegateEvent: (WebSocketDelegateEvent) async -> Void {
        { [weak self] (event: WebSocketDelegateEvent) in
            guard let self = self else { return }

            switch (await self.state, event) {
            case let (.connecting(s1, t1, delegate), .open(s2, t2, _)):
                guard s1 === s2, t1 === t2 else { return }
                await self.setState(.open(s2, t2, delegate))
                await self.onStateChange(.open)

            case let (.connecting(s1, t1, _), .close(s2, t2, closeCode, reason)),
                 let (.open(s1, t1, _), .close(s2, t2, closeCode, reason)):
                guard s1 === s2, t1 === t2 else { return }
                if let closeCode = closeCode {
                    await self.setState(.closed(closeCode, reason))
                } else {
                    await self.setState(.closed(.abnormalClosure, nil))
                }
                await self.onStateChange(.close(.init(closeCode), reason))
                s2.invalidateAndCancel()

            case let (.connecting(s1, t1, _), .complete(s2, t2, error)),
                 let (.open(s1, t1, _), .complete(s2, t2, error)):
                guard s1 === s2, t1 === t2 else { return }
                if let error = error {
                    await self.setState(
                        .closed(
                            .internalServerError,
                            Data(error.localizedDescription.utf8)
                        )
                    )
                    await self.onStateChange(.error(error as NSError))
                } else {
                    await self.setState(.closed(.internalServerError, nil))
                    await self.onStateChange(.close(nil, nil))
                }
                s2.invalidateAndCancel()

            case let (.closing, .close(session, _, closeCode, reason)):
                if let closeCode = closeCode {
                    await self.setState(.closed(closeCode, reason))
                } else {
                    await self.setState(.closed(.abnormalClosure, nil))
                }
                await self.onStateChange(.close(.init(closeCode), reason))
                session.invalidateAndCancel()

            case (.unopened, _):
                return

            case (.closed, _):
                return

            case (.closing, .open), (.closing, .complete):
                return

            case (.open, .open):
                return
            }
        }
    }
}

private enum WebSocketState: CustomStringConvertible {
    case unopened
    case connecting(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
    case open(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
    case closing
    case closed(URLSessionWebSocketTask.CloseCode, Data?)

    var webSocketSessionAndTask: (URLSession, URLSessionWebSocketTask)? {
        switch self {
        case let .connecting(session, task, _), let .open(session, task, _):
            return (session, task)
        case .unopened, .closing, .closed:
            return nil
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
}

// MARK: URLSessionWebSocketDelegate

private enum WebSocketDelegateEvent {
    case open(URLSession, URLSessionWebSocketTask, String?)
    case close(URLSession, URLSessionWebSocketTask, URLSessionWebSocketTask.CloseCode?, Data?)
    case complete(URLSession, URLSessionTask, Error?)
}

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private var onStateChange: (WebSocketDelegateEvent) async -> Void

    init(onStateChange: @escaping (WebSocketDelegateEvent) async -> Void) {
        self.onStateChange = onStateChange
        super.init()
    }

    func urlSession(
        _ webSocketSession: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { await onStateChange(.open(webSocketSession, webSocketTask, `protocol`)) }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Task { await onStateChange(.close(session, webSocketTask, closeCode, reason)) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Task { await onStateChange(.complete(session, task, error)) }
    }
}
