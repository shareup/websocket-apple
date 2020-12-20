import Foundation
import os.log

extension OSLog {
    private static var subsystem =
        Bundle.main.bundleIdentifier ?? "app.shareup.websocket-apple"

    static let webSocket = OSLog(subsystem: subsystem, category: "websocket")
}
