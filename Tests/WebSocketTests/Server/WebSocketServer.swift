import Combine
import Foundation
import NIO
import WebSocket
import WebSocketKit

enum WebSocketServerOutput: Hashable {
    case message(WebSocketMessage)
    case remoteClose
}

final class WebSocketServer {
    var port: Int { _port! }
    private var _port: Int?

    let maximumMessageSize: Int

    // Publisher provided by consumers of `WebSocketServer` to provide the output
    // `WebSocketServer` should send to its clients.
    private let outputPublisher: AnyPublisher<WebSocketServerOutput, Error>
    private var outputPublisherSubscription: AnyCancellable?

    // Publisher that repeats everything sent to it by clients.
    private let inputSubject = PassthroughSubject<WebSocketMessage, Never>()

    private let eventLoopGroup: EventLoopGroup
    private var channel: Channel?

    init<P: Publisher>(
        outputPublisher: P,
        maximumMessageSize: Int = 1024 * 1024
    ) throws where P.Output == WebSocketServerOutput, P.Failure == Error {
        self.outputPublisher = outputPublisher.eraseToAnyPublisher()
        self.maximumMessageSize = maximumMessageSize

        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        channel = try ServerBootstrap
            .webSocket(on: eventLoopGroup) { [weak self] _, ws in
                guard let self else { return }
                subscribeToOutputPublisher(ws)

                ws.onText { [weak self] _, text in
                    self?.inputSubject.send(.text(text))
                }
                ws.onBinary { [weak self] _, binary in
                    var binary = binary
                    guard let data = binary.readData(
                        length: binary.readableBytes,
                        byteTransferStrategy: .copy
                    ) else { return }
                    self?.inputSubject.send(.data(data))
                }
            }.bind(host: "localhost", port: 0).wait()

        _port = channel!.localAddress!.port!
    }

    private func subscribeToOutputPublisher(_ ws: WebSocketKit.WebSocket) {
        outputPublisherSubscription = outputPublisher
            .sink(
                receiveCompletion: { completion in
                    switch completion {
                    case .finished:
                        _ = ws.close(code:)

                    case .failure:
                        _ = ws.close(code: .unexpectedServerError)
                    }
                },
                receiveValue: { output in
                    switch output {
                    case .remoteClose:
                        do { try ws.close(code: .goingAway).wait() }
                        catch {}

                    case let .message(message):
                        switch message {
                        case let .data(data):
                            ws.send(raw: data, opcode: .binary)

                        case let .text(text):
                            ws.send(text)
                        }
                    }
                }
            )
    }

    func shutDown() {
        try? channel?.close(mode: .all).wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    var inputPublisher: AnyPublisher<WebSocketMessage, Never> {
        inputSubject.eraseToAnyPublisher()
    }
}
