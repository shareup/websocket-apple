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

    /// The maximum number of bytes to buffer before the receive call fails with an error.
    /// Default: 1 MiB
    public var maximumMessageSize: Int = 1024 * 1024 {
        didSet { sync {
            guard let (_, task) = state.webSocketSessionAndTask else { return }
            task.maximumMessageSize = maximumMessageSize
        } }
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

    // Deliver messages to the subscribers on a separate thread because it's a bad idea
    // to let the subscribers, who could potentially be doing long-running tasks with the
    // data we send them, block our network thread. However, there's no need to create a
    // special thread for this purpose.
    private let subjectQueue = DispatchQueue(
        label: "WebSocket.subjectQueue",
        attributes: [],
        target: DispatchQueue.global(qos: .default)
    )

    private let webSocketQueue: DispatchQueue = DispatchQueue(label: "WebSocket.webSocketQueue")
    private lazy var delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "WebSocket.delegateQueue"
        queue.maxConcurrentOperationCount = 1
        queue.underlyingQueue = webSocketQueue
        return queue
    }()

    public init(url: URL) {
        self.url = url
    }

    deinit {
        close()
    }

    public func connect() {
        sync {
            switch (state) {
            case .closed, .unopened:
                let delegate = WebSocketDelegate(onOpen: onOpen, onClose: onClose, onCompletion: onCompletion)
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: delegateQueue)
                let task = session.webSocketTask(with: url)
                task.maximumMessageSize = maximumMessageSize
                state = .connecting(session, task, delegate)
                task.resume()
                receiveFromWebSocket()
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

    private func receiveFromWebSocket() {
        webSocketQueue.async {
            let task: URLSessionWebSocketTask? = self.sync {
                let webSocketTask = self.state.webSocketSessionAndTask?.1
                guard let task = webSocketTask, case .running = task.state else { return nil }
                return task
            }

            task?.receive { [weak self] (result: Result<URLSessionWebSocketTask.Message, Error>) in
                guard let self = self else { return }
                let _result = result.map { WebSocketMessage($0) }

                self.subjectQueue.async { [weak self] in self?.subject.send(_result) }
                self.receiveFromWebSocket()
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
        let task: URLSessionWebSocketTask? = sync {
            guard case .open(_, let task, _) = state else {
                completionHandler(WebSocketError.notOpen)
                return nil
            }
            return task
        }

        webSocketQueue.async { task?.send(message, completionHandler: completionHandler) }
    }

    public func close(_ closeCode:  WebSocketCloseCode) {
        let task: URLSessionWebSocketTask? = self.sync {
            guard let (_, task) = self.state.webSocketSessionAndTask else { return nil }
            self.state = .closing
            return task
        }

        webSocketQueue.async {
            let code = URLSessionWebSocketTask.CloseCode(closeCode) ?? .invalid
            task?.cancel(with: code, reason: nil)
        }
    }
}

private typealias OnOpenHandler = (URLSession, URLSessionWebSocketTask, String?) -> Void
private typealias OnCloseHandler = (URLSession, URLSessionWebSocketTask, URLSessionWebSocketTask.CloseCode, Data?) -> Void
private typealias OnCompletionHandler = (URLSession, URLSessionTask, Error?) -> Void

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

                assert(session === webSocketSession)
                assert(task === webSocketTask)

                self.state = .open(webSocketSession, webSocketTask, delegate)
            }

            self.subjectQueue.async { [weak self] in self?.subject.send(.success(.open)) }
        }
    }

    var onClose: OnCloseHandler {
        return { [weak self] (webSocketSession, webSocketTask, closeCode, reason) in
            guard let self = self else { return }

            self.sync {
                if case .closed = self.state { return } // Apple will double close or I would do an assertion failure...
                self.state = .closed(WebSocketError.closed(closeCode, reason))
            }

            self.subjectQueue.async { [weak self] in
                if normalCloseCodes.contains(closeCode) {
                    self?.subject.send(completion: .finished)
                } else {
                    self?.subject.send(completion: .failure(WebSocketError.closed(closeCode, reason)))
                }
            }
        }
    }

    var onCompletion: OnCompletionHandler {
        return { (webSocketSession, webSocketTask, error) in
            webSocketSession.invalidateAndCancel()
        }
    }
}

// MARK: URLSessionWebSocketDelegate

private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
    private let onOpen: OnOpenHandler
    private let onClose: OnCloseHandler
    private let onCompletion: OnCompletionHandler

    init(onOpen: @escaping OnOpenHandler,
         onClose: @escaping OnCloseHandler,
         onCompletion: @escaping OnCompletionHandler)
    {
        self.onOpen = onOpen
        self.onClose = onClose
        self.onCompletion = onCompletion
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

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        self.onCompletion(session, task, error)
    }
}
