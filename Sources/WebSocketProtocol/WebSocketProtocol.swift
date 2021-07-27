import Combine
import Foundation

public protocol WebSocketProtocol: Publisher where Failure == Never, Output == Result<WebSocketMessage, Error> {
    /// The maximum number of bytes to buffer before the receive call fails with an error.
    var maximumMessageSize: Int { get set }

    /// Initializes an instance of `WebSocketProtocol` with the specified `URL`.
    init(url: URL) throws

    /// Connects the socket to the server.
    func connect()

    /// Sends the WebSocket data message, receiving the result in a completion handler.
    func send(_ data: Data, completionHandler: @escaping (Error?) -> Void) throws

    /// Sends the WebSocket text message, receiving the result in a completion handler.
    func send(_ text: String, completionHandler: @escaping (Error?) -> Void) throws

    /// Sends a close frame to the server with the given close code.
    func close(_ closeCode: WebSocketCloseCode)
}

extension WebSocketProtocol {
    /// Calls `WebSocketProtocol.close(closeCode: .goingAway)`.
    public func close() {
        self.close(.goingAway)
    }
}
