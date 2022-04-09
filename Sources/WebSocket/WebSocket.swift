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
        case let .open(session, task, _):
            try await task.send(message)

        case .unopened, .connecting:
            throw WebSocketError.sendMessageWhileConnecting

        case .closing, .closed:
            break
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        switch state {
        case let .open(_, task, _):
            return try await task.receive()

        case .unopened, .connecting, .closing, .closed:
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
            state.debugDescription
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
                guard s1 === s2 && t1 === t2 else { return }
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
                            Data(error.localizedDescription.utf8))
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

private enum WebSocketState: CustomDebugStringConvertible {
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

    var debugDescription: String {
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

private enum WebSocketDelegateEvent  {
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
        Swift.print("$$$ \(#function)")
        Task { await onStateChange(.open(webSocketSession, webSocketTask, `protocol`)) }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        Swift.print("$$$ \(#function)")
        Task { await onStateChange(.close(session, webSocketTask, closeCode, reason)) }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        Swift.print("$$$ \(#function)")
        Task { await onStateChange(.complete(session, task, error)) }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Swift.print("$$$ \(#function): \(String(describing: error))")
    }
}

//private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
//    private let onOpen: OnOpenHandler
//    private let onClose: OnCloseHandler
//    private let onCompletion: OnCompletionHandler
//
//    init(
//        onOpen: @escaping OnOpenHandler,
//        onClose: @escaping OnCloseHandler,
//        onCompletion: @escaping OnCompletionHandler
//    ) {
//        self.onOpen = onOpen
//        self.onClose = onClose
//        self.onCompletion = onCompletion
//        super.init()
//    }
//
//    func urlSession(
//        _ webSocketSession: URLSession,
//        webSocketTask: URLSessionWebSocketTask,
//        didOpenWithProtocol protocol: String?
//    ) {
//        onOpen(webSocketSession, webSocketTask, `protocol`)
//    }
//
//    func urlSession(_ session: URLSession,
//                    webSocketTask: URLSessionWebSocketTask,
//                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
//                    reason: Data?)
//    {
//        onClose(session, webSocketTask, closeCode, reason)
//    }
//
//    func urlSession(_ session: URLSession,
//                    task: URLSessionTask,
//                    didCompleteWithError error: Error?)
//    {
//        onCompletion(session, task, error)
//    }
//}

//public final class WebSocket: WebSocketProtocol {
//    public typealias Output = Result<WebSocketMessage, Swift.Error>
//    public typealias Failure = Swift.Error
//
//    private enum State: CustomDebugStringConvertible {
//        case unopened
//        case connecting(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
//        case open(URLSession, URLSessionWebSocketTask, WebSocketDelegate)
//        case closing
//        case closed(WebSocketError)
//
//        var webSocketSessionAndTask: (URLSession, URLSessionWebSocketTask)? {
//            switch self {
//            case let .connecting(session, task, _), let .open(session, task, _):
//                return (session, task)
//            case .unopened, .closing, .closed:
//                return nil
//            }
//        }
//
//        var debugDescription: String {
//            switch self {
//            case .unopened: return "unopened"
//            case .connecting: return "connecting"
//            case .open: return "open"
//            case .closing: return "closing"
//            case .closed: return "closed"
//            }
//        }
//    }
//
//    /// The maximum number of bytes to buffer before the receive call fails with an error.
//    /// Default: 1 MiB
//    public var maximumMessageSize: Int = 1024 * 1024 {
//        didSet { sync {
//            guard let (_, task) = state.webSocketSessionAndTask else { return }
//            task.maximumMessageSize = maximumMessageSize
//        } }
//    }
//
//    public var isOpen: Bool { sync {
//        guard case .open = state else { return false }
//        return true
//    } }
//
//    public var isClosed: Bool { sync {
//        guard case .closed = state else { return false }
//        return true
//    } }
//
//    private let lock = RecursiveLock()
//    private func sync<T>(_ block: () throws -> T) rethrows -> T { try lock.locked(block) }
//
//    private let url: URL
//
//    private let timeoutIntervalForRequest: TimeInterval
//    private let timeoutIntervalForResource: TimeInterval
//
//    private var state: State = .unopened
//    private let subject = PassthroughSubject<Output, Failure>()
//
//    private let subjectQueue: DispatchQueue
//
//    public convenience init(url: URL) {
//        self.init(url: url, publisherQueue: DispatchQueue.global())
//    }
//
//    public init(
//        url: URL,
//        timeoutIntervalForRequest: TimeInterval = 60, // 60 seconds
//        timeoutIntervalForResource: TimeInterval = 604_800, // 7 days
//        publisherQueue: DispatchQueue = DispatchQueue.global()
//    ) {
//        self.url = url
//        self.timeoutIntervalForRequest = timeoutIntervalForRequest
//        self.timeoutIntervalForResource = timeoutIntervalForResource
//        subjectQueue = DispatchQueue(
//            label: "app.shareup.websocket.subjectqueue",
//            qos: .default,
//            autoreleaseFrequency: .workItem,
//            target: publisherQueue
//        )
//    }
//
//    deinit {
//        close()
//    }
//
//    public func connect() {
//        sync {
//            os_log(
//                "connect: oldstate=%{public}@",
//                log: .webSocket,
//                type: .debug,
//                state.debugDescription
//            )
//
//            switch state {
//            case .closed, .unopened:
//                let delegate = WebSocketDelegate(
//                    onOpen: onOpen,
//                    onClose: onClose,
//                    onCompletion: onCompletion
//                )
//
//                let config = URLSessionConfiguration.default
//                config.timeoutIntervalForRequest = timeoutIntervalForRequest
//                config.timeoutIntervalForResource = timeoutIntervalForResource
//
//                let session = URLSession(
//                    configuration: config,
//                    delegate: delegate,
//                    delegateQueue: nil
//                )
//
//                let task = session.webSocketTask(with: url)
//                task.maximumMessageSize = maximumMessageSize
//                state = .connecting(session, task, delegate)
//                task.resume()
//                receiveFromWebSocket()
//
//            default:
//                break
//            }
//        }
//    }
//
//    public func receive<S: Subscriber>(subscriber: S)
//        where S.Input == Result<WebSocketMessage, Swift.Error>, S.Failure == Swift.Error
//    {
//        subject.receive(subscriber: subscriber)
//    }
//
//    private func receiveFromWebSocket() {
//        let task: URLSessionWebSocketTask? = sync {
//            let webSocketTask = self.state.webSocketSessionAndTask?.1
//            guard let task = webSocketTask, case .running = task.state else { return nil }
//            return task
//        }
//
//        task?.receive
//            { [weak self, weak task] (result: Result<URLSessionWebSocketTask.Message, Error>) in
//                guard let self = self else { return }
//
//                let _result = result.map { WebSocketMessage($0) }
//
//                guard task?.state == .running
//                else {
//                    os_log(
//                        "receive message in incorrect task state: message=%s taskstate=%{public}@",
//                        log: .webSocket,
//                        type: .debug,
//                        _result.debugDescription,
//                        "\(task?.state.rawValue ?? -1)"
//                    )
//                    return
//                }
//
//                os_log("receive: %s", log: .webSocket, type: .debug, _result.debugDescription)
//                self.subjectQueue.async { [weak self] in self?.subject.send(_result) }
//                self.receiveFromWebSocket()
//            }
//    }
//
//    public func send(
//        _ string: String,
//        completionHandler: @escaping (Error?) -> Void = { _ in }
//    ) {
//        os_log("send: %s", log: .webSocket, type: .debug, string)
//        send(.string(string), completionHandler: completionHandler)
//    }
//
//    public func send(_ data: Data, completionHandler: @escaping (Error?) -> Void = { _ in }) {
//        os_log("send: %lld bytes", log: .webSocket, type: .debug, data.count)
//        send(.data(data), completionHandler: completionHandler)
//    }
//
//    private func send(
//        _ message: URLSessionWebSocketTask.Message,
//        completionHandler: @escaping (Error?) -> Void
//    ) {
//        let task: URLSessionWebSocketTask? = sync {
//            guard case let .open(_, task, _) = state, task.state == .running
//            else {
//                os_log(
//                    "send message in incorrect task state: message=%s taskstate=%{public}@",
//                    log: .webSocket,
//                    type: .debug,
//                    message.debugDescription,
//                    "\(self.state.webSocketSessionAndTask?.1.state.rawValue ?? -1)"
//                )
//                completionHandler(WebSocketError.notOpen)
//                return nil
//            }
//            return task
//        }
//
//        task?.send(message, completionHandler: completionHandler)
//    }
//
//    public func close(_ closeCode: WebSocketCloseCode) {
//        let task: URLSessionWebSocketTask? = sync {
//            os_log(
//                "close: oldstate=%{public}@ code=%lld",
//                log: .webSocket,
//                type: .debug,
//                state.debugDescription,
//                closeCode.rawValue
//            )
//
//            guard let (_, task) = state.webSocketSessionAndTask, task.state == .running
//            else { return nil }
//            state = .closing
//            return task
//        }
//
//        let code = URLSessionWebSocketTask.CloseCode(closeCode) ?? .invalid
//        task?.cancel(with: code, reason: nil)
//    }
//}
//
//private typealias OnOpenHandler = (URLSession, URLSessionWebSocketTask, String?) -> Void
//private typealias OnCloseHandler = (
//    URLSession,
//    URLSessionWebSocketTask,
//    URLSessionWebSocketTask.CloseCode,
//    Data?
//) -> Void
//private typealias OnCompletionHandler = (URLSession, URLSessionTask, Error?) -> Void
//
//private let normalCloseCodes: [URLSessionWebSocketTask.CloseCode] = [.goingAway, .normalClosure]
//
//// MARK: onOpen and onClose
//
//private extension WebSocket {
//    var onOpen: OnOpenHandler {
//        { [weak self] webSocketSession, webSocketTask, _ in
//            guard let self = self else { return }
//
//            self.sync {
//                os_log(
//                    "onOpen: oldstate=%{public}@",
//                    log: .webSocket,
//                    type: .debug,
//                    self.state.debugDescription
//                )
//
//                guard case let .connecting(session, task, delegate) = self.state else {
//                    os_log(
//                        "receive onOpen callback in incorrect state: oldstate=%{public}@",
//                        log: .webSocket,
//                        type: .error,
//                        self.state.debugDescription
//                    )
//                    self.state = .open(
//                        webSocketSession,
//                        webSocketTask,
//                        webSocketSession.delegate as! WebSocketDelegate
//                    )
//                    return
//                }
//
//                assert(session === webSocketSession)
//                assert(task === webSocketTask)
//
//                self.state = .open(webSocketSession, webSocketTask, delegate)
//            }
//
//            self.subjectQueue.async { [weak self] in self?.subject.send(.success(.open)) }
//        }
//    }
//
//    var onClose: OnCloseHandler {
//        { [weak self] _, _, closeCode, reason in
//            guard let self = self else { return }
//
//            self.sync {
//                os_log(
//                    "onClose: oldstate=%{public}@ code=%lld",
//                    log: .webSocket,
//                    type: .debug,
//                    self.state.debugDescription,
//                    closeCode.rawValue
//                )
//
//                if case .closed = self.state { return }
//                self.state = .closed(WebSocketError.closed(closeCode, reason))
//
//                self.subjectQueue.async { [weak self] in
//                    if normalCloseCodes.contains(closeCode) {
//                        self?.subject.send(completion: .finished)
//                    } else {
//                        self?.subject.send(
//                            completion: .failure(WebSocketError.closed(closeCode, reason))
//                        )
//                    }
//                }
//            }
//        }
//    }
//
//    var onCompletion: OnCompletionHandler {
//        { [weak self] webSocketSession, _, error in
//            defer { webSocketSession.invalidateAndCancel() }
//            guard let self = self else { return }
//
//            os_log("onCompletion", log: .webSocket, type: .debug)
//
//            // "The only errors your delegate receives through the error parameter
//            // are client-side errors, such as being unable to resolve the hostname
//            // or connect to the host."
//            //
//            // https://developer.apple.com/documentation/foundation/urlsessiontaskdelegate/1411610-urlsession
//            //
//            // When receiving these errors, `onClose` is not called because the connection
//            // was never actually opened.
//            guard let error = error else { return }
//            self.sync {
//                os_log(
//                    "onCompletion: oldstate=%{public}@ error=%@",
//                    log: .webSocket,
//                    type: .debug,
//                    self.state.debugDescription,
//                    error.localizedDescription
//                )
//
//                if case .closed = self.state { return }
//                self.state = .closed(.notOpen)
//
//                self.subjectQueue.async { [weak self] in
//                    self?.subject.send(completion: .failure(error))
//                }
//            }
//        }
//    }
//}
//
//// MARK: URLSessionWebSocketDelegate
//
//private class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate {
//    private let onOpen: OnOpenHandler
//    private let onClose: OnCloseHandler
//    private let onCompletion: OnCompletionHandler
//
//    init(onOpen: @escaping OnOpenHandler,
//         onClose: @escaping OnCloseHandler,
//         onCompletion: @escaping OnCompletionHandler)
//    {
//        self.onOpen = onOpen
//        self.onClose = onClose
//        self.onCompletion = onCompletion
//        super.init()
//    }
//
//    func urlSession(_ webSocketSession: URLSession,
//                    webSocketTask: URLSessionWebSocketTask,
//                    didOpenWithProtocol protocol: String?)
//    {
//        onOpen(webSocketSession, webSocketTask, `protocol`)
//    }
//
//    func urlSession(_ session: URLSession,
//                    webSocketTask: URLSessionWebSocketTask,
//                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
//                    reason: Data?)
//    {
//        onClose(session, webSocketTask, closeCode, reason)
//    }
//
//    func urlSession(_ session: URLSession,
//                    task: URLSessionTask,
//                    didCompleteWithError error: Error?)
//    {
//        onCompletion(session, task, error)
//    }
//}
