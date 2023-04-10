import Foundation
import os.log

extension OSLog {
    static let webSocket = OSLog(subsystem: subsystem, category: "websocket")
}

private let subsystem =
    Bundle.main.bundleIdentifier ?? "app.shareup.websocket-apple"
