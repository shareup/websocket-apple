import Foundation

public struct WebSocketOptions: Hashable {
    public var maximumMessageSize: Int
    public var timeoutIntervalForRequest: TimeInterval
    public var timeoutIntervalForResource: TimeInterval

    public init(
        maximumMessageSize: Int = 1024 * 1024, // 1 MiB
        timeoutIntervalForRequest: TimeInterval = 60, // 60 seconds
        timeoutIntervalForResource: TimeInterval = 604_800 // 7 days
    ) {
        self.maximumMessageSize = maximumMessageSize
        self.timeoutIntervalForRequest = timeoutIntervalForRequest
        self.timeoutIntervalForResource = timeoutIntervalForResource
    }
}
