import Foundation
import WebSocketProtocol

public enum WebSocketError: Error {
    case invalidURL(URL)
    case invalidURLComponents(URLComponents)
    case notOpen
    case closed(WebSocketCloseCode, Data?)
}
