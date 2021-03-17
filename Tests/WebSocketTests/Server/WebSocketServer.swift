import Foundation
import NIO
import NIOHTTP1
import NIOWebSocket

enum ReplyType {
    case echo
    case reply(() -> String?)
    case matchReply((String) -> String?)
}

final class WebSocketServer {
    let port: UInt16

    private let replyType: ReplyType
    private let eventLoopGroup: EventLoopGroup

    private var serverChannel: Channel?

    init(port: UInt16, replyProvider: ReplyType) {
        self.port = port
        replyType = replyProvider
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    func listen() {
        do {
            var addr = sockaddr_in()
            addr.sin_port = in_port_t(port).bigEndian
            let address = SocketAddress(addr, host: "0.0.0.0")

            let bootstrap = makeBootstrap()
            serverChannel = try bootstrap.bind(to: address).wait()

            guard let localAddress = serverChannel?.localAddress else {
                throw NIO.ChannelError.unknownLocalAddress
            }
            print("WebSocketServer running on \(localAddress)")
        } catch let error as NIO.IOError {
            print("Failed to start server: \(error.errnoCode) '\(error.localizedDescription)'")
        } catch {
            print("Failed to start server: \(String(describing: error))")
        }
    }

    func close() {
        do { try serverChannel?.close().wait() }
        catch { print("Failed to wait on server: \(error)") }
    }

    private func shouldUpgrade(channel _: Channel,
                               head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    {
        let headers = head.uri.starts(with: "/socket") ? HTTPHeaders() : nil
        return eventLoopGroup.next().makeSucceededFuture(headers)
    }

    private func upgradePipelineHandler(channel: Channel, head: HTTPRequestHead) -> NIO
        .EventLoopFuture<Void>
    {
        head.uri.starts(with: "/socket") ?
            channel.pipeline.addHandler(WebSocketHandler(replyProvider: replyProvider)) : channel
            .closeFuture
    }

    private var replyProvider: (String) -> String? {
        { [weak self] (input: String) -> String? in
            guard let self = self else { return nil }
            switch self.replyType {
            case .echo:
                return input
            case let .reply(iterator):
                return iterator()
            case let .matchReply(matcher):
                return matcher(input)
            }
        }
    }

    private func makeBootstrap() -> ServerBootstrap {
        let reuseAddrOpt = ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_REUSEADDR)
        return ServerBootstrap(group: eventLoopGroup)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(reuseAddrOpt, value: 1)
            .childChannelInitializer { channel in
                let connectionUpgrader = NIOWebSocketServerUpgrader(
                    shouldUpgrade: self.shouldUpgrade,
                    upgradePipelineHandler: self.upgradePipelineHandler
                )

                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [connectionUpgrader],
                    completionHandler: { _ in }
                )

                return channel.pipeline.configureHTTPServerPipeline(
                    position: .first,
                    withPipeliningAssistance: true,
                    withServerUpgrade: config,
                    withErrorHandling: true
                )
            }
            .childChannelOption(ChannelOptions.socket(IPPROTO_TCP, TCP_NODELAY), value: 1)
            .childChannelOption(reuseAddrOpt, value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 1)
    }
}

private class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let replyProvider: (String) -> String?
    private var awaitingClose = false

    init(replyProvider: @escaping (String) -> String?) {
        self.replyProvider = replyProvider
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)

        switch frame.opcode {
        case .connectionClose:
            onClose(context: context, frame: frame)
        case .ping:
            onPing(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            onText(context: context, text: text)
        case .binary:
            let buffer = frame.unmaskedData
            var data = Data(capacity: buffer.readableBytes)
            buffer.withUnsafeReadableBytes { data.append(contentsOf: $0) }
            onBinary(context: context, binary: data)
        default:
            onError(context: context)
        }
    }

    private func onBinary(context: ChannelHandlerContext, binary: Data) {
        do {
            // Obviously, this would need to be changed to actually handle data input
            if let text = String(data: binary, encoding: .utf8) {
                onText(context: context, text: text)
            } else {
                throw NIO.IOError(errnoCode: EBADMSG, reason: "Invalid message")
            }
        } catch {
            onError(context: context)
        }
    }

    private func onText(context: ChannelHandlerContext, text: String) {
        guard let reply = replyProvider(text) else { return }

        var replyBuffer = context.channel.allocator.buffer(capacity: reply.utf8.count)
        replyBuffer.writeString(reply)

        let frame = WebSocketFrame(fin: true, opcode: .text, data: replyBuffer)

        _ = context.channel.writeAndFlush(frame)
    }

    private func onPing(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data

        if let maskingKey = frame.maskKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let pong = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        context.write(wrapOutboundOut(pong), promise: nil)
    }

    private func onClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        if awaitingClose {
            // We sent the initial close and were waiting for the client's response
            context.close(promise: nil)
        } else {
            // The close came from the client.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? context.channel.allocator
                .buffer(capacity: 0)
            let closeFrame = WebSocketFrame(
                fin: true,
                opcode: .connectionClose,
                data: closeDataCode
            )
            _ = context.write(wrapOutboundOut(closeFrame)).map { () in
                context.close(promise: nil)
            }
        }
    }

    private func onError(context: ChannelHandlerContext) {
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
        awaitingClose = true
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    func channelActive(context: ChannelHandlerContext) {
        print("Channel active: \(String(describing: context.channel.remoteAddress))")
    }

    func channelInactive(context: ChannelHandlerContext) {
        print("Channel closed: \(String(describing: context.localAddress))")
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        print("Error: \(error)")
        context.close(promise: nil)
    }
}
