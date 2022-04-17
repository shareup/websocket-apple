import Combine
import Foundation
import Network
import WebSocket

enum WebSocketServerError: Error {
    case couldNotCreatePort(UInt16)
}

enum WebSocketServerOutput: Hashable {
    case die
    case message(WebSocketMessage)
}

private typealias E = WebSocketServerError

final class WebSocketServer {
    let port: UInt16
    let maximumMessageSize: Int

    // Publisher provided by consumers of `WebSocketServer` to provide the output
    // `WebSocketServer` should send to its clients.
    private let outputPublisher: AnyPublisher<WebSocketServerOutput, Error>
    private var outputPublisherSubscription: AnyCancellable?

    // Publisher the repeats everything sent to it by clients.
    private let inputSubject = PassthroughSubject<WebSocketMessage, Never>()

    private var listener: NWListener
    private var connections: [NWConnection] = []

    private let queue = DispatchQueue(
        label: "app.shareup.websocketserverqueue",
        qos: .default,
        autoreleaseFrequency: .workItem,
        target: .global()
    )

    init<P: Publisher>(
        port: UInt16,
        outputPublisher: P,
        usesTLS: Bool = false,
        maximumMessageSize: Int = 1024 * 1024
    ) throws where P.Output == WebSocketServerOutput, P.Failure == Error {
        self.port = port
        self.outputPublisher = outputPublisher.eraseToAnyPublisher()
        self.maximumMessageSize = maximumMessageSize

        let parameters = NWParameters(tls: usesTLS ? .init() : nil)
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = true
        parameters.acceptLocalOnly = true

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.maximumMessageSize = maximumMessageSize

        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        guard let port = NWEndpoint.Port(rawValue: port)
        else { throw E.couldNotCreatePort(port) }

        listener = try NWListener(using: parameters, on: port)

        start()
    }

    func forceClose() {
        queue.sync {
            connections.forEach { connection in
                connection.forceCancel()
            }
            connections.removeAll()
            listener.cancel()
        }
    }

    var inputPublisher: AnyPublisher<WebSocketMessage, Never> {
        inputSubject.eraseToAnyPublisher()
    }
}

private extension WebSocketServer {
    func start() {
        listener.newConnectionHandler = onNewConnection

        listener.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .failed:
                self.close()

            default:
                break
            }
        }

        listener.start(queue: queue)
    }

    func broadcastMessage(_ message: WebSocketMessage) {
        let context: NWConnection.ContentContext
        let content: Data

        switch message {
        case let .data(data):
            let metadata: NWProtocolWebSocket.Metadata = .init(opcode: .binary)
            context = .init(identifier: String(message.hashValue), metadata: [metadata])
            content = data

        case let .text(string):
            let metadata: NWProtocolWebSocket.Metadata = .init(opcode: .text)
            context = .init(identifier: String(message.hashValue), metadata: [metadata])
            content = Data(string.utf8)
        }

        connections.forEach { connection in
            connection.send(
                content: content,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { [weak self] error in
                    guard let _ = error else { return }
                    self?.closeConnection(connection)
                }
            )
        }
    }

    func close() {
        connections.forEach { closeConnection($0) }
        connections.removeAll()
        listener.cancel()
    }

    func closeConnection(_ connection: NWConnection) {
        connection.send(
            content: nil,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }

    func cancelConnection(_ connection: NWConnection) {
        connection.forceCancel()
        connections.removeAll(where: { $0 === connection })
    }

    var onNewConnection: (NWConnection) -> Void {
        { [weak self] (newConnection: NWConnection) in
            guard let self = self else { return }

            self.connections.append(newConnection)

            func receive() {
                newConnection.receiveMessage { [weak self] data, context, _, error in
                    guard let self = self else { return }
                    guard error == nil else { return self.closeConnection(newConnection) }

                    guard let data = data,
                          let context = context,
                          let _metadata = context.protocolMetadata.first,
                          let metadata = _metadata as? NWProtocolWebSocket.Metadata
                    else { return }

                    switch metadata.opcode {
                    case .binary:
                        self.inputSubject.send(.data(data))

                    case .text:
                        if let text = String(data: data, encoding: .utf8) {
                            self.inputSubject.send(.text(text))
                        }

                    default:
                        break
                    }

                    receive()
                }
            }
            receive()

            newConnection.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }

                switch state {
                case .ready:
                    guard self.outputPublisherSubscription == nil else { break }
                    self.outputPublisherSubscription = self.outputPublisher
                        .receive(on: self.queue)
                        .sink(
                            receiveCompletion: { [weak self] completion in
                                guard let self = self else { return }
                                guard case .failure = completion else {
                                    self.cancelConnection(newConnection)
                                    return
                                }
                                self.close()
                            },
                            receiveValue: { [weak self] (output: WebSocketServerOutput) in
                                guard let self = self else { return }
                                switch output {
                                case .die:
                                    self.cancelConnection(newConnection)

                                case let .message(message):
                                    self.broadcastMessage(message)
                                }
                            }
                        )

                case .failed:
                    self.cancelConnection(newConnection)

                default:
                    break
                }
            }

            newConnection.start(queue: self.queue)
        }
    }
}
