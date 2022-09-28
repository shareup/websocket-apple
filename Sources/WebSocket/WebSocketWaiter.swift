import DispatchTimer
import Foundation
import Synchronized

private typealias WaiterContinuation = CheckedContinuation<Void, Error>

final class WebSocketWaiter: Sendable {
    private let state = Locked(State())

    func open(timeout: TimeInterval) async throws {
        let id = UUID().uuidString
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (cont: WaiterContinuation) in
                    let timer = DispatchTimer(fireAt: deadline(timeout)) { [weak self] in
                        let res = self?.state.access { $0.opens.remove(id) }
                        res?.timer.invalidate()
                        res?.continuation.resume(throwing: CancellationError())
                    }

                    let res = Resumption(id, cont, timer)
                    let block: (() -> Void)? = state.access { state in
                        guard state.isUnopened else {
                            switch state.connection {
                            case .unopened:
                                return {
                                    timer.invalidate()
                                    preconditionFailure()
                                }

                            case .open:
                                return {
                                    timer.invalidate()
                                    cont.resume()
                                }

                            case let .closed(error):
                                return {
                                    timer.invalidate()
                                    cont.resume(throwing: error ?? WebSocketError.closed)
                                }
                            }
                        }

                        state.opens.append(res)
                        return nil
                    }

                    block?()
                }
            },
            onCancel: { [weak self] in
                let res = self?.state.access { $0.opens.remove(id) }
                res?.timer.invalidate()
                res?.continuation.resume(throwing: CancellationError())
            }
        )
    }

    func close(timeout: TimeInterval) async throws {
        Swift.print("$$$ \(#function)")
        let id = UUID().uuidString
        try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { (cont: WaiterContinuation) in
                    let timer = DispatchTimer(fireAt: deadline(timeout)) { [weak self] in
                        let res = self?.state.access { $0.closes.remove(id) }
                        res?.timer.invalidate()
                        res?.continuation.resume(throwing: CancellationError())
                    }

                    let res = Resumption(id, cont, timer)
                    let block: (() -> Void)? = state.access { state in
                        if case let .closed(error) = state.connection {
                            return {
                                timer.invalidate()
                                if let error = error {
                                    cont.resume(throwing: error)
                                } else {
                                    cont.resume()
                                }
                            }
                        } else {
                            state.closes.append(res)
                            return nil
                        }
                    }

                    block?()
                }
            },
            onCancel: { [weak self] in
                let res = self?.state.access { $0.opens.remove(id) }
                res?.timer.invalidate()
                res?.continuation.resume(throwing: CancellationError())
            }
        )
    }

    func didOpen() {
        let opens: [Resumption] = state.access { state in
            precondition(state.isUnopened)
            state.connection = .open

            let opens = state.opens
            state.opens.removeAll()
            return opens
        }

        opens.forEach {
            $0.timer.invalidate()
            $0.continuation.resume()
        }
    }

    func didClose(error: WebSocketError?) {
        let (opens, closes): ([Resumption], [Resumption]) = state.access { state in
            state.connection = .closed(error)

            let opens = state.opens
            let closes = state.closes
            state.opens.removeAll()
            state.closes.removeAll()
            return (opens, closes)
        }

        opens.forEach { `open` in
            `open`.timer.invalidate()
            `open`.continuation.resume(throwing: error ?? WebSocketError.closed)
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
        let resumptions: [Resumption] = state.access { state in
            state.connection = .closed(CancellationError())

            let opens = state.opens
            let closes = state.closes
            state.opens.removeAll()
            state.closes.removeAll()
            return opens + closes
        }
        resumptions.forEach { res in
            res.timer.invalidate()
            res.continuation.resume(throwing: CancellationError())
        }
    }
}

private extension WebSocketWaiter {
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

private struct State: Sendable {
    enum Connection {
        case unopened
        case open
        case closed(Error?)
    }

    var connection: Connection = .unopened

    var opens: [Resumption] = []
    var closes: [Resumption] = []

    var isUnopened: Bool {
        guard case .unopened = connection else { return false }
        return true
    }

    var isOpen: Bool {
        guard case .open = connection else { return false }
        return true
    }

    var isClosed: Bool {
        guard case .closed = connection else { return false }
        return true
    }
}

private extension Array where Element == Resumption {
    mutating func remove(_ id: String) -> Resumption? {
        guard let index = firstIndex(where: { $0.id == id })
        else { return nil }
        return remove(at: index)
    }
}
