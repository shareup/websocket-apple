import Foundation
import Synchronized

func webSocketTask(
    for url: URL,
    options: WebSocketOptions,
    onOpen: @escaping () async -> Void,
    onClose: @escaping (WebSocketCloseCode, Data?) async -> Void
) -> URLSessionWebSocketTask {
    let session = session(for: options)

    let task = session.webSocketTask(with: url)
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

private final class Delegate: NSObject, URLSessionWebSocketDelegate, Sendable {
    private struct Callbacks {
        let onOpen: () async -> Void
        let onClose: (WebSocketCloseCode, Data?) async -> Void
    }

    // `Dictionary<ObjectIdentifier(URLWebSocketTask): Callbacks>`
    private let state: Locked<[ObjectIdentifier: Callbacks]> = .init([:])

    func set(
        onOpen: @escaping () async -> Void,
        onClose: @escaping (WebSocketCloseCode, Data?) async -> Void,
        for taskID: ObjectIdentifier
    ) {
        state.access { $0[taskID] = .init(onOpen: onOpen, onClose: onClose) }
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol _: String?
    ) {
        let taskID = ObjectIdentifier(webSocketTask)

        if let onOpen = state.access({ $0[taskID]?.onOpen }) {
            Task { await onOpen() }
        }
    }

    func urlSession(
        _: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let taskID = ObjectIdentifier(webSocketTask)

        if let onClose = state.access({ $0[taskID]?.onClose }) {
            Task { await onClose(WebSocketCloseCode(closeCode), reason) }
        }
    }

    func urlSession(
        _: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskID = ObjectIdentifier(task)

        if let onClose = state.access({ $0[taskID]?.onClose }) {
            Task { [weak self] in
                if let error {
                    await onClose(
                        .abnormalClosure,
                        Data(error.localizedDescription.utf8)
                    )
                } else {
                    await onClose(.normalClosure, nil)
                }

                self?.state.access { _ = $0.removeValue(forKey: taskID) }
            }
        }
    }
}
