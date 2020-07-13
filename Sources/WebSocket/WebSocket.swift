import Combine
import Foundation
import Network
import Synchronized
import WebSocketProtocol

public final class WebSocket: WebSocketProtocol, Identifiable {
    public typealias Output = Result<WebSocketMessage, Swift.Error>
    public typealias Failure = Swift.Error

    private enum State {
        case unopened
        case connecting(NWConnection)
        case open(NWConnection)
        case closing(NWError?)
        case closed(WebSocketError)
        
        var connection: NWConnection? {
            switch self {
            case .unopened, .closing, .closed:
                return nil
            case let .connecting(conn), let .open(conn):
                return conn
            }
        }
    }
    
    public let id: String = UUID().uuidString

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

    // Deliver messages to the subscribers on a separate queue because it's a bad idea
    // to let the subscribers, who could potentially be doing long-running tasks with the
    // data we send them, block our network queue. However, there's no need to create a
    // special thread for this purpose.
    private let subjectQueue = DispatchQueue(
        label: "com.shareup.WebSocket.subjectQueue",
        attributes: [],
        target: DispatchQueue.global(qos: .default)
    )

    private let webSocketQueue: DispatchQueue =
        DispatchQueue(label: "com.shareup.WebSocket.webSocketQueue")

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
                do {
                    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                        throw WebSocketError.invalidURL(url)
                    }

                    let parameters = try self.parameters(with: components)
                    let connection = NWConnection(to: .url(url), using: parameters)
                    state = .connecting(connection)
                    connection.stateUpdateHandler = self.onStateUpdate
                    connection.start(queue: webSocketQueue)
                } catch let error as WebSocketError {
                    state = .closed(error)
                    subject.send(completion: .failure(error))
                } catch {
                    subject.send(completion: .failure(error))
                }
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

    public func send(_ string: String, completionHandler: @escaping (Error?) -> Void = { _ in }) {
        let connection: NWConnection? = sync {
            guard case .open(let conn) = state else {
                completionHandler(WebSocketError.notOpen)
                return nil
            }
            return conn
        }

        let text = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: String(string.hashValue), metadata: [text])

        webSocketQueue.async {
            connection?.send(
                content: Data(string.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed(completionHandler)
            )
        }
    }

    public func send(_ data: Data, completionHandler: @escaping (Error?) -> Void = { _ in }) {
        let connection: NWConnection? = sync {
            guard case .open(let conn) = state else {
                completionHandler(WebSocketError.notOpen)
                return nil
            }
            return conn
        }

        let binary = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: String(data.hashValue), metadata: [binary])

        webSocketQueue.async {
            connection?.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed(completionHandler)
            )
        }
    }

    public func close(_ closeCode:  WebSocketCloseCode) {
        let connection: NWConnection? = sync {
            guard let conn = state.connection else { return nil }
            self.state = .closing(closeCode.error)
            return conn
        }

        webSocketQueue.async { connection?.cancel() }
    }
}

private extension NWConnection.ContentContext {
    var webSocketMetadata: NWProtocolWebSocket.Metadata? {
        let definition = NWProtocolWebSocket.definition
        return self.protocolMetadata(definition: definition) as? NWProtocolWebSocket.Metadata
    }

    var websocketMessageType: NWProtocolWebSocket.Opcode? {
        return webSocketMetadata?.opcode
    }
}

private extension WebSocket {
    func handleMessage(data: Data, context: NWConnection.ContentContext) {
        let conn: NWConnection? = sync {
            switch state {
            case .connecting(let conn):
                // I don't think this should be called...
                Swift.print(".connecting", String(data: data, encoding: .utf8) ?? "")
                return conn
            case .open(let conn):
                return conn
            default:
                Swift.print("Unexpected message while '\(state)': \(String(data: data, encoding: .utf8) ?? "")")
                return nil
            }
        }

        guard let connection = conn else { return }

        switch context.websocketMessageType {
        case .binary:
            subjectQueue.async { [weak self] in self?.subject.send(.success(.data(data))) }
        case .text:
            guard let text = String(data: data, encoding: .utf8) else {
                close(.unsupportedData)
                return
            }
            subjectQueue.async { [weak self] in self?.subject.send(.success(.text(text))) }
        case .close:
            sync {
                state = .closing(nil)
            }
        case .pong:
            Swift.print(".pong")
            break
        default:
            assertionFailure("Unexpected message type: \(String(describing: context.websocketMessageType))")
            break
        }

        connection.receiveMessage(completion: onReceiveMessage)
    }

    func handleMessage(error: NWError) {
        sync {
            // TODO: What should we do here? We'll probably have to handle specific errors and
            // close on all of the rest, I guess?
            switch state {
            case .connecting(let conn), .open(let conn):
                if error.shouldCloseConnectionWhileConnectingOrOpen {
                    close(error.closeCode)
                    subjectQueue.async { [weak self] in
                        self?.subject.send(.failure(error))
                    }
                    state = .closing(error)
                }
            default:
                break
            }
        }
    }

    func handleUnknownMessage(data: Data?, context: NWConnection.ContentContext?, error: NWError?) {
        func describeInputs() -> String {
            return
                String(describing: String(data: data ?? Data(), encoding: .utf8)) + " " +
                String(describing: context) + " " + String(describing: error)
        }

        Swift.print(#function, describeInputs())

        sync {
            switch self.state {
            case .connecting(let conn), .open(let conn):
                close(.unsupportedData)
            default:
                assertionFailure("Unknown message: \(describeInputs())")
                break
            }
        }
    }
}

private extension WebSocket {
    func host(with urlComponents: URLComponents) throws -> NWEndpoint.Host {
        guard let host = urlComponents.host else {
            throw WebSocketError.invalidURLComponents(urlComponents)
        }
        return NWEndpoint.Host(host)
    }
    
    func port(with urlComponents: URLComponents) throws -> NWEndpoint.Port {
        if let raw = urlComponents.port, let port = NWEndpoint.Port(rawValue: UInt16(raw)) {
            return port
        } else if "ws" == urlComponents.scheme {
             return NWEndpoint.Port.http
         } else if "wss" == urlComponents.scheme {
             return NWEndpoint.Port.https
         } else  {
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
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocketOptions, at: 0)

        return parameters
    }
}

private typealias OnStateUpdateHandler = (NWConnection.State) -> Void
private typealias OnReceiveMessageHandler = (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

// MARK: onOpen and onClose

private extension WebSocket  {
    var onStateUpdate: OnStateUpdateHandler {
        return { [weak self] (state) -> Void in
            guard let self = self else { return }

            Swift.print(#function, String(describing: state))

            switch state {
            case .setup:
                break
            case .waiting:
                break
            case .preparing:
                break
            case .ready:
                self.sync {
                    switch self.state {
                    case .connecting(let conn):
                        self.state = .open(conn)
                        self.subjectQueue.async { [weak self] in
                            self?.subject.send(.success(.open))
                        }
                        conn.receiveMessage(completion: self.onReceiveMessage)
                    case .open:
                        // TODO: Handle betterPathUpdate here?
                        break
                    default:
                        assertionFailure("Unexpected .ready message while '\(self.state)'")
                        break
                    }
                }
            case .failed(let error):
                self.sync {
                    switch self.state {
                    case .connecting(let conn), .open(let conn):
                        self.state = .closing(error)
                        self.subjectQueue.async { [weak self] in
                            self?.subject.send(.failure(error))
                        }
                        conn.cancel()
                    case .closing(let error):
                        Swift.print("Received .failed(\(String(describing: error))) while '\(self.state)'")
                        break
                    default:
                        assertionFailure("Unexpected .failed(\(error)) message while '\(self.state)'")
                        break
                    }
                }
            case .cancelled:
                self.sync {
                    switch self.state {
                    case .connecting, .open, .closing(nil):
                        self.state = .closed(.closed(.normalClosure, nil))
                        self.subjectQueue.async { [weak self] in
                            self?.subject.send(completion: .finished)
                        }
                    case .closing(.some(let error)):
                        self.state = .closed(error.webSocketError)
                        self.subjectQueue.async { [weak self] in
                            self?.subject.send(completion: .failure(error))
                        }
                    default:
                        Swift.print("Unexpected .cancelled message while '\(self.state)'")
                        break
                    }
                }
            @unknown default:
                assertionFailure("Unknown state '\(state)'")
            }
        }
    }

    var onReceiveMessage: OnReceiveMessageHandler {
        return { [weak self] (data, context, isMessageComplete, error) -> Void in
            guard let self = self else { return }
            guard isMessageComplete else { return }

            switch (data, context, error) {
            case let (.some(data), .some(context), .none):
                self.handleMessage(data: data, context: context)
            case let (.none, _, .some(error)):
                self.handleMessage(error: error)
            default:
                self.handleUnknownMessage(data: data, context: context, error: error)
            }
        }
    }

//    var onOpen: OnOpenHandler {
//        return { [weak self] (webSocketSession, webSocketTask, `protocol`) in
//            guard let self = self else { return }
//
//            self.sync {
//                guard case let .connecting(session, task, delegate) = self.state else {
//                    assertionFailure("Should not have received `didOpenWithProtocol` while in '\(self.state)'")
//                    self.state = .open(webSocketSession, webSocketTask, webSocketSession.delegate as! WebSocketDelegate)
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
//        return { [weak self] (webSocketSession, webSocketTask, closeCode, reason) in
//            guard let self = self else { return }
//
//            self.sync {
//                if case .closed = self.state { return } // Apple will double close or I would do an assertion failure...
//                self.state = .closed(WebSocketError.closed(closeCode, reason))
//            }
//
//            self.subjectQueue.async { [weak self] in
//                if normalCloseCodes.contains(closeCode) {
//                    self?.subject.send(completion: .finished)
//                } else {
//                    self?.subject.send(completion: .failure(WebSocketError.closed(closeCode, reason)))
//                }
//            }
//        }
//    }
//
//    var onCompletion: OnCompletionHandler {
//        return { (webSocketSession, webSocketTask, error) in
//            webSocketSession.invalidateAndCancel()
//        }
//    }
}

// MARK: URLSessionWebSocketDelegate

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
//                    didOpenWithProtocol protocol: String?) {
//        self.onOpen(webSocketSession, webSocketTask, `protocol`)
//    }
//
//    func urlSession(_ session: URLSession,
//                    webSocketTask: URLSessionWebSocketTask,
//                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
//                    reason: Data?) {
//        self.onClose(session, webSocketTask, closeCode, reason)
//    }
//
//    func urlSession(_ session: URLSession,
//                    task: URLSessionTask,
//                    didCompleteWithError error: Error?) {
//        self.onCompletion(session, task, error)
//    }
//}
