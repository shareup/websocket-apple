import Foundation

public enum WebSocketError: Error, Hashable {
    case sendMessageWhileConnecting
    case receiveMessageWhenNotOpen
    case receiveUnknownMessageType
    case expectedTextReceivedData
    case expectedDataReceivedText
}
