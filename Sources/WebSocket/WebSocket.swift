import Combine
import Foundation
import Synchronized
import WebSocketProtocol

public final class WebSocket: WebSocketProtocol {
    public typealias Output = Result<WebSocketMessage, Swift.Error>
    public typealias Failure = Swift.Error

    private enum State {
        case unopened
        case connecting(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
        case open(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
        case closing
        case closed(WebSocketError)

        var webSocketSessionAndTask: (URLSession, URLSessionWebSocketTask)? {
            switch self {
            case let .connecting(session, task, _), let .open(session, task, _):
                return (session, task)
            case .unopened, .closing, .closed:
                return nil
            }
        }
    }

    public var isOpen: Bool { sync {
        guard case .open = state else { return false }
        return true
    } }

    public var isClosed: Bool { sync {
        guard case .closed = state else { return false }
        return true
    } }

    private let lock: RecursiveLock = RecursiveLock()
    private func sync<T>(_ block: () throws -> T) rethrows -> T { return try lock.locked(block) }

    private let url: URL

    private var state: State = .unopened
    private let subject = PassthroughSubject<Output, Failure>()

    private let serialQueue: DispatchQueue = DispatchQueue(label: "WebSocket.serialQueue")
    private lazy var delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WebSocket.delegateQueue"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = serialQueue
        return queue
    }()

    public init(url: URL) {
        self.url = url
        connect()
    }

    deinit {
        close()
    }

    private func connect() {
        sync {
            switch (state) {
            case .closed, .unopened:
                let delegate = WebSocketDelegate(onOpen: onOpen, onClose: onClose)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: delegateQueue)
                let task = session.webSocketTask(with: url)
                state = .connecting(session, task, delegate)
                task.receive() { [weak self] in self?.receiveFromWebSocket($0) }
                task.resume()
            default:
                break
            }
        }
    }

    public func receive<S: Subscriber>(subscriber: S)
        where S.Input == Result<WebSocketMessage, Swift.Error>, S.Failure == Swift.Error
    {
        subject.receive(subscriber: subscriber)
    }

    private func receiveFromWebSocket(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        let _result = result.map { WebSocketMessage($0) }

        subject.send(_result)

        sync {
            if case .open(_, let task, _) = state,
                case .running = task.state {
                task.receive() { [weak self] in self?.receiveFromWebSocket($0) }
            }
        }
    }

    public func send(_ string: String, completionHandler: @escaping (Error?) -> Void = { _ in }) {
        send(.string(string), completionHandler: completionHandler)
    }

    public func send(_ data: Data, completionHandler: @escaping (Error?) -> Void = { _ in }) {
        send(.data(data), completionHandler: completionHandler)
    }

    private func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping (Error?) -> Void) {
        sync {
            guard case .open(_, let task, _) = state else {
                completionHandler(WebSocketError.notOpen)
                return
            }

            task.send(message, completionHandler: completionHandler)
        }
    }

    public func close() {
        close(.goingAway)
    }

    // TODO: make a list of close codes to expose publicly instead of depending on URLSessionWebSocketTask.CloseCode
    func close(_ closeCode:  URLSessionWebSocketTask.CloseCode) {
        let webSocket: (URLSession, URLSessionWebSocketTask)? = sync {
            guard let (session, task) = state.webSocketSessionAndTask else { return nil }
            state = .closing
            return (session, task)
        }

        guard let (session, task) = webSocket else { return }
        task.cancel(with: closeCode, reason: nil)
        session.invalidateAndCancel()
    }
}

private typealias OnOpenHandler = (URLSession, URLSessionWebSocketTask, String?) -> Void
private typealias OnCloseHandler = (URLSession, URLSessionWebSocketTask, URLSessionWebSocketTask.CloseCode, Data?) -> Void

private let normalCloseCodes: [URLSessionWebSocketTask.CloseCode] = [.goingAway, .normalClosure]

// MARK: onOpen and onClose

private extension WebSocket  {
    var onOpen: OnOpenHandler {
        return { [weak self] (webSocketSession, webSocketTask, `protocol`) in
            guard let self = self else { return }

            self.sync {
                guard case let .connecting(session, task, delegate) = self.state else {
                    assertionFailure("Should not have received `didOpenWithProtocol` while in '\(self.state)'")
                    self.state = .open(webSocketSession, webSocketTask, webSocketSession.delegate as! WebSocketDelegate)
                    return
                }

                assert(session == webSocketSession)
                assert(task == webSocketTask)

                self.state = .open(webSocketSession, webSocketTask, delegate)
            }

            self.subject.send(.success(.open))
        }
    }

    var onClose: OnCloseHandler {
        return { [weak self] (webSocketSession, webSocketTask, closeCode, reason) in
            guard let self = self else { return }

            self.sync {
                if case .closed = self.state { return } // Apple will double close or I would do an assertion failure...
                self.state = .closed(WebSocketError.closed(closeCode, reason))
            }

            if normalCloseCodes.contains(closeCode) {
                self.subject.send(completion: .finished)
            } else {
                self.subject.send(completion: .failure(WebSocketError.closed(closeCode, reason)))
            }
        }
    }
}

// MARK: URLSessionWebSocketDelegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private let onOpen: OnOpenHandler
    private let onClose: OnCloseHandler

    init(onOpen: @escaping OnOpenHandler, onClose: @escaping OnCloseHandler) {
        self.onOpen = onOpen
        self.onClose = onClose
        super.init()
    }

    func urlSession(_ webSocketSession: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        self.onOpen(webSocketSession, webSocketTask, `protocol`)
    }

    func urlSession(_ session: URLSession,
                    webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                    reason: Data?) {
        self.onClose(session, webSocketTask, closeCode, reason)
    }
}
