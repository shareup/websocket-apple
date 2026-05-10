import Combine
import Foundation
import NIO
import NIOWebSocket
import WebSocket
import WebSocketKit

enum WebSocketServerOutput {
    case message(WebSocketMessage)
    case ping(Data)
    case remoteClose
    case remoteCloseWithReason(WebSocketErrorCode, Data)
}

final class WebSocketServer {
    var port: Int { channel!.localAddress!.port! }

    let maximumMessageSize: Int

    // Publisher provided by consumers of `WebSocketServer` to provide the output
    // `WebSocketServer` should send to its clients.
    private let outputPublisher: AnyPublisher<WebSocketServerOutput, Error>
    private var outputPublisherSubscription: AnyCancellable?

    // Publisher that repeats everything sent to it by clients.
    private let inputSubject = PassthroughSubject<WebSocketMessage, Never>()
    private let pongSubject = PassthroughSubject<Data, Never>()

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
                ws.onPong { [weak self] _, pong in
                    var pong = pong
                    guard let data = pong.readData(
                        length: pong.readableBytes,
                        byteTransferStrategy: .copy
                    ) else { return }
                    self?.pongSubject.send(data)
                }
            }.bind(host: "127.0.0.1", port: 0).wait()
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
                    case let .ping(data):
                        ws.sendPing(data)

                    case .remoteClose:
                        do { try ws.close(code: .goingAway).wait() }
                        catch {}

                    case let .remoteCloseWithReason(code, reason):
                        var buffer = ByteBufferAllocator().buffer(capacity: 2 + reason.count)
                        buffer.write(webSocketErrorCode: code)
                        buffer.writeBytes(reason)
                        ws.send(
                            raw: buffer.readableBytesView,
                            opcode: .connectionClose
                        )

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

    var pongPublisher: AnyPublisher<Data, Never> {
        pongSubject.eraseToAnyPublisher()
    }
}
