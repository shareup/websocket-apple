import Foundation

extension URLSessionWebSocketTask.Message: CustomDebugStringConvertible {
    public var debugDescription: String {
        switch self {
        case let .string(text):
            return text
        case let .data(data):
            return "\(data.count) bytes"
        @unknown default:
            assertionFailure("Unsupported message: \(self)")
            return "<unknown>"
        }
    }
}
