import Foundation
import Synchronized

func webSocketTask(
    for request: URLRequest,
    options: WebSocketOptions,
    onOpen: @escaping @Sendable () async -> Void,
    onClose: @escaping @Sendable (WebSocketCloseCode, Data?) async -> Void
) -> URLSessionWebSocketTask {
    let session = session(for: options)

    let task = session.webSocketTask(with: request)
    task.maximumMessageSize = options.maximumMessageSize

    let delegate = session.delegate as! Delegate
    delegate.set(onOpen: onOpen, onClose: onClose, for: ObjectIdentifier(task))

    return task
}

func cancelAndInvalidateAllTasks() {
    sessions.access { sessions in
        sessions.forEach { $0.value.invalidateAndCancel() }
        sessions.removeAll()
    }
}

private let sessions = Locked<[WebSocketOptions: URLSession]>([:])

private func session(for options: WebSocketOptions) -> URLSession {
    sessions.access { sessions in
        if let session = sessions[options] {
            return session
        } else {
            let session = URLSession(
                configuration: configuration(with: options),
                delegate: Delegate(),
                delegateQueue: nil
            )

            sessions[options] = session

            return session
        }
    }
}

private func configuration(with options: WebSocketOptions) -> URLSessionConfiguration {
    let config = URLSessionConfiguration.default
    config.waitsForConnectivity = false
    config.timeoutIntervalForRequest = options.timeoutIntervalForRequest
    config.timeoutIntervalForResource = options.timeoutIntervalForResource
    return config
}

final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct Callbacks: Sendable {
        let onOpen: @Sendable () async -> Void
        let onClose: @Sendable (WebSocketCloseCode, Data?) async -> Void
    }

    private struct State: Sendable {
        var callbacks: [ObjectIdentifier: Callbacks] = [:]
        var callbackTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    }

    private let state = Locked(State())

    func set(
        onOpen: @escaping @Sendable () async -> Void,
        onClose: @escaping @Sendable (WebSocketCloseCode, Data?) async -> Void,
        for taskID: ObjectIdentifier
    ) {
        state.access { state in
            state.callbacks[taskID] = .init(
                onOpen: onOpen,
                onClose: onClose
            )
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let taskID = ObjectIdentifier(webSocketTask)
        enqueue(for: taskID) { callbacks in
            await callbacks.onOpen()
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let taskID = ObjectIdentifier(webSocketTask)
        enqueue(for: taskID) { callbacks in
            await callbacks.onClose(WebSocketCloseCode(closeCode), reason)
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = ObjectIdentifier(task)
        let closeCode: WebSocketCloseCode = error == nil ? .normalClosure : .abnormalClosure
        let reason = error.map { Data($0.localizedDescription.utf8) }
        enqueue(for: taskID, removeAfterwards: true) { callbacks in
            await callbacks.onClose(closeCode, reason)
        }
    }

    private func enqueue(
        for taskID: ObjectIdentifier,
        removeAfterwards: Bool = false,
        _ operation: @escaping @Sendable (Callbacks) async -> Void
    ) {
        state.access { state in
            guard let callbacks = state.callbacks[taskID] else {
                return
            }

            let previousTask = state.callbackTasks[taskID]
            let task = Task { [weak self] in
                _ = await previousTask?.result
                await operation(callbacks)

                guard removeAfterwards else { return }
                self?.state.access { state in
                    _ = state.callbacks.removeValue(forKey: taskID)
                    _ = state.callbackTasks.removeValue(forKey: taskID)
                }
            }

            state.callbackTasks[taskID] = task
        }
    }
}
