import DispatchTimer
import Foundation
import Synchronized

private typealias WaiterContinuation = CheckedContinuation<Void, Error>

final class WebSocketWaiter: Sendable {
    private let resumptions = Locked(Resumptions())

    func open(
        timeout: TimeInterval,
        isOpen: @escaping @Sendable () async -> Bool
    ) async throws {
        try await add(\Resumptions.opens, timeout: timeout, doubleCheck: isOpen)
    }

    func addClose(
        timeout: TimeInterval,
        isClosed: @escaping @Sendable () async -> Bool
    ) async throws {
        try await add(\Resumptions.closes, timeout: timeout, doubleCheck: isClosed)
    }

    func didOpen() {
        let opens: [Resumption] = resumptions.access { res in
            let opens = res.opens
            res.opens.removeAll()
            return opens
        }
        opens.forEach {
            $0.timer.invalidate()
            $0.continuation.resume()
        }
    }

    func didClose(error: WebSocketError?) {
        let (opens, closes): ([Resumption], [Resumption]) = resumptions.access { res in
            let opens = res.opens
            let closes = res.closes
            res.opens.removeAll()
            res.closes.removeAll()
            return (opens, closes)
        }
        opens.forEach { open in
            open.timer.invalidate()
            open.continuation.resume(throwing: error ?? WebSocketError.closed)
        }
        closes.forEach { close in
            close.timer.invalidate()
            if let error = error {
                close.continuation.resume(throwing: error)
            } else {
                close.continuation.resume()
            }
        }
    }

    func cancelAll() {
        let resumptions: [Resumption] = resumptions.access { res in
            let opens = res.opens
            let closes = res.closes
            res.opens.removeAll()
            res.closes.removeAll()
            return opens + closes
        }
        resumptions.forEach { res in
            res.timer.invalidate()
            res.continuation.resume(throwing: CancellationError())
        }
    }
}

private extension WebSocketWaiter {
    private func add(
        _ keyPath: WritableKeyPath<Resumptions, [Resumption]>,
        timeout: TimeInterval,
        doubleCheck: @escaping @Sendable () async -> Bool
    ) async throws {
        let id = UUID().uuidString
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (cont: WaiterContinuation) in
                    let timer = DispatchTimer(fireAt: deadline(timeout)) { [weak self] in
                        let res = self?.resumptions
                            .access { $0[keyPath: keyPath].remove(id) }
                        res?.timer.invalidate()
                        res?.continuation.resume(throwing: CancellationError())
                    }

                    let res = Resumption(id, cont, timer)
                    resumptions.access { $0[keyPath: keyPath].append(res) }

                    Task {
                        // There's a race condition where the state may have
                        // changed before the resumption was added, which means
                        // the continuation would not be resumed until it
                        // times out. This acts as a double-check to make sure
                        // we resume the continuation if the state has already
                        // changed.
                        if !Task.isCancelled, await doubleCheck() {
                            let res = resumptions.access { res in
                                res[keyPath: keyPath].remove(id)
                            }
                            res?.timer.invalidate()
                            res?.continuation.resume()
                        }
                    }
                }

            },
            onCancel: { [weak self] in
                let res = self?.resumptions.access { $0[keyPath: keyPath].remove(id) }
                res?.timer.invalidate()
                res?.continuation.resume(throwing: CancellationError())
            }
        )
    }

    private func deadline(_ timeout: TimeInterval) -> DispatchTime {
        let _timeout = max(timeout, 0.01)
        let nanoseconds = Int(_timeout * Double(NSEC_PER_SEC))
        return .now() + .nanoseconds(nanoseconds)
    }
}

private struct Resumption: Identifiable, Sendable {
    let id: String
    let continuation: WaiterContinuation
    let timer: DispatchTimer

    init(_ id: String, _ continuation: WaiterContinuation, _ timer: DispatchTimer) {
        self.id = id
        self.continuation = continuation
        self.timer = timer
    }
}

private struct Resumptions: Sendable {
    var opens: [Resumption] = []
    var closes: [Resumption] = []
}

private extension Array where Element == Resumption {
    mutating func remove(_ id: String) -> Resumption? {
        guard let index = firstIndex(where: { $0.id == id })
        else { return nil }
        return remove(at: index)
    }
}
