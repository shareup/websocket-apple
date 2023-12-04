import Combine
import Foundation
import NIO
import NIOHTTP1
import NIOSSL
import NIOWebSocket
import WebSocket
import WebSocketKit

enum WebSocketServerOutput: Hashable {
    case message(WebSocketMessage)
    case remoteClose
}

private typealias WS = WebSocketKit.WebSocket

final class WebSocketServer {
    var port: Int { _port! }
    private var _port: Int?

    let maximumMessageSize: Int

    // Publisher provided by consumers of `WebSocketServer` to provide the output
    // `WebSocketServer` should send to its clients.
    private let outputPublisher: AnyPublisher<WebSocketServerOutput, Error>
    private var outputPublisherSubscription: AnyCancellable?

    // Publisher the repeats everything sent to it by clients.
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

        channel = try makeWebSocket(
            on: eventLoopGroup,
            onUpgrade: onWebSocketUpgrade
        )
        .bind(to: SocketAddress(
            ipAddress: "127.0.0.1",
            port: 0 // random port
        ))
        .wait()

        if let port = channel?.localAddress?.port {
            _port = port
        }
    }

    private func makeWebSocket(
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @escaping (HTTPRequestHead, WS) -> Void
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR),
                value: 1
            )
            .childChannelInitializer { channel in
                let ws = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in
                        channel.eventLoop.makeSucceededFuture([:])
                    },
                    upgradePipelineHandler: { channel, req in
                        WebSocket.server(on: channel) { ws in
                            onUpgrade(req, ws)
                        }
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(
                    withServerUpgrade: (
                        upgraders: [ws],
                        completionHandler: { _ in }
                    )
                )
            }
    }

    private var onWebSocketUpgrade: (HTTPRequestHead, WS) -> Void {
        { [weak self] (_: HTTPRequestHead, ws: WS) in
            guard let self else { return }

            let sub = outputPublisher
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

            outputPublisherSubscription = sub

            ws.onText { [weak self] _, text in
                self?.inputSubject.send(.text(text))
            }

            ws.onBinary { [weak self] _, buffer in
                guard let self,
                      let data = buffer.getData(
                          at: buffer.readerIndex,
                          length: buffer.readableBytes
                      )
                else { return }
                inputSubject.send(.data(data))
            }
        }
    }

    func shutDown() {
        try? channel?.close(mode: .all).wait()
        try? eventLoopGroup.syncShutdownGracefully()
    }

    var inputPublisher: AnyPublisher<WebSocketMessage, Never> {
        inputSubject.eraseToAnyPublisher()
    }
}
