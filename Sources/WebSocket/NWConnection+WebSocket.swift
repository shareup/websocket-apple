import Foundation
import Network

extension NWConnection {
    func cancelIfNeeded() {
        switch state {
        case .setup, .waiting, .preparing, .ready:
            cancel()

        case .failed, .cancelled:
            break

        @unknown default:
            assertionFailure("Unknown state '\(state)'")
        }
    }
}
