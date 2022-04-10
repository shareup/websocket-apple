import NIO
import NIOWebSocket
import NIOHTTP1
import NIOSSL
import Foundation
import NIOFoundationCompat

enum ReplyType {
    case echo
    case reply(() -> String?)
    case matchReply((String) -> String?)
}

final class WebSocketServer  {
    enum PeerType {
        case server
        case client
    }

    var eventLoop: EventLoop {
        return channel.eventLoop
    }

    var isClosed: Bool { !self.channel.isActive }
    private(set) var closeCode: WebSocketErrorCode?

    var onClose: EventLoopFuture<Void> {
        self.channel.closeFuture
    }

    let port: UInt16

    private let replyType: ReplyType
    private let eventLoopGroup: EventLoopGroup

    private var channel: Channel!
    private var onTextCallback: (WebSocketServer, String) -> ()
    private var onBinaryCallback: (WebSocketServer, ByteBuffer) -> ()
    private var onPongCallback: (WebSocketServer) -> ()
    private var onPingCallback: (WebSocketServer) -> ()
    private var frameSequence: WebSocketFrameSequence?
    private let type: PeerType
    private var waitingForPong: Bool
    private var waitingForClose: Bool
    private var scheduledTimeoutTask: Scheduled<Void>?

    init(port: UInt16, replyProvider: ReplyType) throws {
        self.port = port
        replyType = replyProvider
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        self.type = .server
        self.onTextCallback = { _, _ in }
        self.onBinaryCallback = { _, _ in }
        self.onPongCallback = { _ in }
        self.onPingCallback = { _ in }
        self.waitingForPong = false
        self.waitingForClose = false
        self.scheduledTimeoutTask = nil

        var addr = sockaddr_in()
        addr.sin_port = in_port_t(port).bigEndian
        let address = SocketAddress(addr, host: "0.0.0.0")

        let bootstrap = makeBootstrap()
        let channel = try bootstrap.bind(to: address).wait()

        guard let localAddress = channel.localAddress else {
            throw NIO.ChannelError.unknownLocalAddress
        }

        self.channel = channel

        print("WebSocketServer running on \(localAddress)")
    }

    deinit {
        assert(self.isClosed, "WebSocketServer was not closed before deinit.")
    }

    func onText(_ callback: @escaping (WebSocketServer, String) -> ()) {
        self.onTextCallback = callback
    }

    func onBinary(_ callback: @escaping (WebSocketServer, ByteBuffer) -> ()) {
        self.onBinaryCallback = callback
    }

    func onPong(_ callback: @escaping (WebSocketServer) -> ()) {
        self.onPongCallback = callback
    }

    func onPing(_ callback: @escaping (WebSocketServer) -> ()) {
        self.onPingCallback = callback
    }

    /// If set, this will trigger automatic pings on the connection. If ping is not answered before
    /// the next ping is sent, then the WebSocketServer will be presumed innactive and will be closed
    /// automatically.
    /// These pings can also be used to keep the WebSocketServer alive if there is some other timeout
    /// mechanism shutting down innactive connections, such as a Load Balancer deployed in
    /// front of the server.
    var pingInterval: TimeAmount? {
        didSet {
            if pingInterval != nil {
                if scheduledTimeoutTask == nil {
                    waitingForPong = false
                    self.pingAndScheduleNextTimeoutTask()
                }
            } else {
                scheduledTimeoutTask?.cancel()
            }
        }
    }

    func send<S>(_ text: S, promise: EventLoopPromise<Void>? = nil)
        where S: Collection, S.Element == Character
    {
        let string = String(text)
        var buffer = channel.allocator.buffer(capacity: text.count)
        buffer.writeString(string)
        self.send(raw: buffer.readableBytesView, opcode: .text, fin: true, promise: promise)
    }

    func send(_ binary: [UInt8], promise: EventLoopPromise<Void>? = nil) {
        self.send(raw: binary, opcode: .binary, fin: true, promise: promise)
    }

    func sendPing(promise: EventLoopPromise<Void>? = nil) {
        self.send(
            raw: Data(),
            opcode: .ping,
            fin: true,
            promise: promise
        )
    }

    func send<Data>(
        raw data: Data,
        opcode: WebSocketOpcode,
        fin: Bool = true,
        promise: EventLoopPromise<Void>? = nil
    )
        where Data: DataProtocol
    {
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        let frame = WebSocketFrame(
            fin: fin,
            opcode: opcode,
            maskKey: self.makeMaskKey(),
            data: buffer
        )
        self.channel.writeAndFlush(frame, promise: promise)
    }

    func close(code: WebSocketErrorCode = .goingAway) -> EventLoopFuture<Void> {
        let promise = self.eventLoop.makePromise(of: Void.self)
        self.close(code: code, promise: promise)
        return promise.futureResult
    }

    func close(
        code: WebSocketErrorCode = .goingAway,
        promise: EventLoopPromise<Void>?
    ) {
        guard !self.isClosed else {
            promise?.succeed(())
            return
        }
        guard !self.waitingForClose else {
            promise?.succeed(())
            return
        }
        self.waitingForClose = true
        self.closeCode = code

        let codeAsInt = UInt16(webSocketErrorCode: code)
        let codeToSend: WebSocketErrorCode
        if codeAsInt == 1005 || codeAsInt == 1006 {
            /// Code 1005 and 1006 are used to report errors to the application, but must never be sent over
            /// the wire (per https://tools.ietf.org/html/rfc6455#section-7.4)
            codeToSend = .normalClosure
        } else {
            codeToSend = code
        }

        var buffer = channel.allocator.buffer(capacity: 2)
        buffer.write(webSocketErrorCode: codeToSend)

        self.send(raw: buffer.readableBytesView, opcode: .connectionClose, fin: true, promise: promise)
    }

    func makeMaskKey() -> WebSocketMaskingKey? {
        switch type {
        case .client:
            var bytes: [UInt8] = []
            for _ in 0..<4 {
                bytes.append(.random(in: .min ..< .max))
            }
            return WebSocketMaskingKey(bytes)
        case .server:
            return nil
        }
    }

    func handle(incoming frame: WebSocketFrame) {
        switch frame.opcode {
        case .connectionClose:
            if self.waitingForClose {
                // peer confirmed close, time to close channel
                self.channel.close(mode: .all, promise: nil)
            } else {
                // peer asking for close, confirm and close output side channel
                let promise = self.eventLoop.makePromise(of: Void.self)
                var data = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    data.webSocketUnmask(maskingKey)
                }
                self.close(
                    code: data.readWebSocketErrorCode() ?? .unknown(1005),
                    promise: promise
                )
                promise.futureResult.whenComplete { _ in
                    self.channel.close(mode: .all, promise: nil)
                }
            }
        case .ping:
            if frame.fin {
                var frameData = frame.data
                let maskingKey = frame.maskKey
                if let maskingKey = maskingKey {
                    frameData.webSocketUnmask(maskingKey)
                }
                self.send(
                    raw: frameData.readableBytesView,
                    opcode: .pong,
                    fin: true,
                    promise: nil
                )
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        case .text, .binary, .pong:
            // create a new frame sequence or use existing
            var frameSequence: WebSocketFrameSequence
            if let existing = self.frameSequence {
                frameSequence = existing
            } else {
                frameSequence = WebSocketFrameSequence(type: frame.opcode)
            }
            // append this frame and update the sequence
            frameSequence.append(frame)
            self.frameSequence = frameSequence
        case .continuation:
            // we must have an existing sequence
            if var frameSequence = self.frameSequence {
                // append this frame and update
                frameSequence.append(frame)
                self.frameSequence = frameSequence
            } else {
                self.close(code: .protocolError, promise: nil)
            }
        default:
            // We ignore all other frames.
            break
        }

        // if this frame was final and we have a non-nil frame sequence,
        // output it to the websocket and clear storage
        if let frameSequence = self.frameSequence, frame.fin {
            switch frameSequence.type {
            case .binary:
                self.onBinaryCallback(self, frameSequence.binaryBuffer)
            case .text:
                self.onTextCallback(self, frameSequence.textBuffer)
            case .pong:
                self.waitingForPong = false
                self.onPongCallback(self)
            case .ping:
                self.onPingCallback(self)
            default: break
            }
            self.frameSequence = nil
        }
    }

    private func pingAndScheduleNextTimeoutTask() {
        guard channel.isActive, let pingInterval = pingInterval else {
            return
        }

        if waitingForPong {
            // We never received a pong from our last ping, so the connection has timed out
            let promise = self.eventLoop.makePromise(of: Void.self)
            self.close(code: .unknown(1006), promise: promise)
            promise.futureResult.whenComplete { _ in
                // Usually, closing a WebSocketServer is done by sending the close frame and waiting
                // for the peer to respond with their close frame. We are in a timeout situation,
                // so the other side likely will never send the close frame. We just close the
                // channel ourselves.
                self.channel.close(mode: .all, promise: nil)
            }
        } else {
            self.sendPing()
            self.waitingForPong = true
            self.scheduledTimeoutTask = self.eventLoop.scheduleTask(
                deadline: .now() + pingInterval,
                self.pingAndScheduleNextTimeoutTask
            )
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

    private func shouldUpgrade(channel _: Channel,
                               head: HTTPRequestHead) -> EventLoopFuture<HTTPHeaders?>
    {
        let headers = head.uri.starts(with: "/socket") ? HTTPHeaders() : nil
        return eventLoopGroup.next().makeSucceededFuture(headers)
    }

    private func upgradePipelineHandler(
        channel: Channel,
        head: HTTPRequestHead
    ) -> NIO.EventLoopFuture<Void> {
        head.uri.starts(with: "/socket") ?
            channel.pipeline.addHandler(WebSocketHandler(replyType: replyType)) :
            channel.closeFuture
    }
}

private final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private var awaitingClose: Bool = false
    private let replyType: ReplyType

    init(replyType: ReplyType) {
        self.replyType = replyType
    }

    private func replyProvider(input: String) -> String? {
        switch replyType {
        case .echo:
            return input
        case let .reply(iterator):
            return iterator()
        case let .matchReply(matcher):
            return matcher(input)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)

        func handleText(_ text: String) {
            guard let reply = replyProvider(input: text) else { return }
            let buffer = context.channel.allocator.buffer(data: Data(reply.utf8))
            let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
            context.writeAndFlush(self.wrapOutboundOut(frame)).whenFailure { _ in
                context.close(promise: nil)
            }
        }

        switch frame.opcode {
        case .connectionClose:
            self.receivedClose(context: context, frame: frame)
        case .ping:
            self.pong(context: context, frame: frame)
        case .text:
            var data = frame.unmaskedData
            let text = data.readString(length: data.readableBytes) ?? ""
            handleText(text)

        case .binary:
            let buffer = frame.unmaskedData
            var data = Data(capacity: buffer.readableBytes)
            buffer.withUnsafeReadableBytes { data.append(contentsOf: $0) }

            if let text = String(data: data, encoding: .utf8) {
                handleText(text)
            } else {
                closeOnError(context: context)
            }

        case .continuation, .pong:
            // We ignore these frames.
            break
        default:
            // Unknown frames are errors.
            self.closeOnError(context: context)
        }
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }

    private func sendTime(context: ChannelHandlerContext) {
        guard context.channel.isActive else { return }

        // We can't send if we sent a close message.
        guard !self.awaitingClose else { return }

        // We can't really check for error here, but it's also not the purpose of the
        // example so let's not worry about it.
        let theTime = NIODeadline.now().uptimeNanoseconds
        var buffer = context.channel.allocator.buffer(capacity: 12)
        buffer.writeString("\(theTime)")

        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(self.wrapOutboundOut(frame)).map {
            context.eventLoop.scheduleTask(in: .seconds(1), { self.sendTime(context: context) })
        }.whenFailure { (_: Error) in
            context.close(promise: nil)
        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        // Handle a received close frame. In websockets, we're just going to send the close
        // frame and then close, unless we already sent our own close frame.
        if awaitingClose {
            // Cool, we started the close and were waiting for the user. We're done.
            context.close(promise: nil)
        } else {
            // This is an unsolicited close. We're going to send a response frame and
            // then, when we've sent it, close up shop. We should send back the close code the remote
            // peer sent us, unless they didn't send one at all.
            var data = frame.unmaskedData
            let closeDataCode = data.readSlice(length: 2) ?? ByteBuffer()
            let closeFrame = WebSocketFrame(fin: true, opcode: .connectionClose, data: closeDataCode)
            _ = context.write(self.wrapOutboundOut(closeFrame)).map { () in
                context.close(promise: nil)
            }
        }
    }

    private func pong(context: ChannelHandlerContext, frame: WebSocketFrame) {
        var frameData = frame.data
        let maskingKey = frame.maskKey

        if let maskingKey = maskingKey {
            frameData.webSocketUnmask(maskingKey)
        }

        let responseFrame = WebSocketFrame(fin: true, opcode: .pong, data: frameData)
        context.write(self.wrapOutboundOut(responseFrame), promise: nil)
    }

    private func closeOnError(context: ChannelHandlerContext) {
        // We have hit an error, we want to close. We do that by sending a close frame and then
        // shutting down the write side of the connection.
        var data = context.channel.allocator.buffer(capacity: 2)
        data.write(webSocketErrorCode: .protocolError)
        let frame = WebSocketFrame(fin: true, opcode: .connectionClose, data: data)
        context.write(self.wrapOutboundOut(frame)).whenComplete { (_: Result<Void, Error>) in
            context.close(mode: .output, promise: nil)
        }
        awaitingClose = true
    }
}

private struct WebSocketFrameSequence {
    var binaryBuffer: ByteBuffer
    var textBuffer: String
    var type: WebSocketOpcode

    init(type: WebSocketOpcode) {
        self.binaryBuffer = ByteBufferAllocator().buffer(capacity: 0)
        self.textBuffer = .init()
        self.type = type
    }

    mutating func append(_ frame: WebSocketFrame) {
        var data = frame.unmaskedData
        switch type {
        case .binary:
            self.binaryBuffer.writeBuffer(&data)
        case .text:
            if let string = data.readString(length: data.readableBytes) {
                self.textBuffer += string
            }
        default: break
        }
    }
}
