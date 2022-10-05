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
    let port: UInt16
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
        port: UInt16,
        outputPublisher: P,
        usesTLS: Bool = false,
        maximumMessageSize: Int = 1024 * 1024
    ) throws where P.Output == WebSocketServerOutput, P.Failure == Error {
        print("$$$ PORT: \(port)")
        self.port = port
        self.outputPublisher = outputPublisher.eraseToAnyPublisher()
        self.maximumMessageSize = maximumMessageSize

        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        do {
            channel = try makeWebSocket(
                on: eventLoopGroup,
                onUpgrade: onWebSocketUpgrade
            )
            .bind(host: "0.0.0.0", port: Int(port))
            .wait()
        } catch let error as IOError where error.errnoCode == 48 {
            // Address already in use
            print("$$$ \(port) is already in use")
        }
    }

    private func makeWebSocket(
        on eventLoopGroup: EventLoopGroup,
        onUpgrade: @escaping (HTTPRequestHead, WS) -> Void
    ) -> ServerBootstrap {
        ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { (channel: Channel) in
                let ws = NIOWebSocketServerUpgrader(
                    shouldUpgrade: { channel, _ in
                        channel.eventLoop.makeSucceededFuture([:])
                    },
                    upgradePipelineHandler: { channel, req in
                        WS.server(on: channel) { onUpgrade(req, $0) }
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
        { [weak self] (req: HTTPRequestHead, ws: WS) in
            guard let self else { return }

            let sub = self.outputPublisher
                .sink(
                    receiveCompletion: { completion in
                        switch completion {
                        case .finished:
                            let _ = ws.close(code:)

                        case .failure:
                            let _ = ws.close(code: .unexpectedServerError)
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

            self.outputPublisherSubscription = sub

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
                self.inputSubject.send(.data(data))
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
