import Synchronized
@testable import WebSocket
import XCTest

final class WebSocketWaiterTests: XCTestCase {
    func testOpen() async throws {
        let socket = Socket()
        let didOpen = Locked(false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.waiter.open(timeout: 0.5) { await socket.isOpen }
                didOpen.access { $0 = true }
            }

            group.addTask {
                try await socket.open(after: 0.01)
            }

            try await group.waitForAll()
        }

        XCTAssertTrue(didOpen.access { $0 })
    }

    func testOpenFailsWithError() async throws {
        let socket = Socket()
        let didFail = Locked(false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await socket.waiter.open(timeout: 0.5) { await socket.isOpen }
                    XCTFail()
                } catch {
                    XCTAssertEqual(
                        WebSocketError.receiveUnknownMessageType,
                        error as? WebSocketError
                    )
                    didFail.access { $0 = true }
                }
            }

            group.addTask {
                try await socket.closeWithError(after: 0.01)
            }

            try await group.waitForAll()
        }

        XCTAssertTrue(didFail.access { $0 })
    }

    func testMultipleOpens() async throws {
        let socket = Socket()
        let openCount = Locked(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            (0..<100).forEach { i in
                group.addTask {
                    try await socket.waiter.open(timeout: 0.5) { await socket.isOpen }
                    openCount.access { $0 += 1 }
                }
            }

            group.addTask { try await socket.open(after: 0.00001) }

            try await group.waitForAll()
        }

        XCTAssertEqual(100, openCount.access { $0 })
    }

    func testClose() async throws {
        let socket = Socket()
        let didClose = Locked(false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await socket.waiter.close(timeout: 0.5) { await socket.isClosed }
                didClose.access { $0 = true }
            }

            group.addTask {
                try await socket.close(after: 0.01)
            }

            try await group.waitForAll()
        }

        XCTAssertTrue(didClose.access { $0 })
    }

    func testCloseWithError() async throws {
        let socket = Socket()
        let didCloseWithError = Locked(false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await socket.waiter.close(timeout: 0.5) { await socket.isClosed }
                    XCTFail()
                } catch {
                    XCTAssertEqual(
                        WebSocketError.receiveUnknownMessageType,
                        error as? WebSocketError
                    )
                    didCloseWithError.access { $0 = true }
                }
            }

            group.addTask {
                try await socket.closeWithError(after: 0.01)
            }

            try await group.waitForAll()
        }

        XCTAssertTrue(didCloseWithError.access { $0 })
    }

    func testMultipleCloses() async throws {
        let socket = Socket()
        let closeCount = Locked(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            (0..<100).forEach { i in
                group.addTask {
                    try await socket.waiter.close(timeout: 0.5) { await socket.isClosed }
                    closeCount.access { $0 += 1 }
                }
            }

            group.addTask { try await socket.close(after: 0.00001) }

            try await group.waitForAll()
        }

        XCTAssertEqual(100, closeCount.access { $0 })
    }

    func testOpenAndCloseBothFailWithError() async throws {
        let socket = Socket()
        let openFails = Locked(false)
        let didCloseWithError = Locked(false)

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    try await socket.waiter.open(timeout: 0.5) { await socket.isOpen }
                    XCTFail()
                } catch {
                    XCTAssertEqual(
                        WebSocketError.receiveUnknownMessageType,
                        error as? WebSocketError
                    )
                    openFails.access { $0 = true }
                }
            }

            group.addTask {
                do {
                    try await socket.waiter.close(timeout: 0.5) { await socket.isClosed }
                    XCTFail()
                } catch {
                    XCTAssertEqual(
                        WebSocketError.receiveUnknownMessageType,
                        error as? WebSocketError
                    )
                    didCloseWithError.access { $0 = true }
                }
            }

            group.addTask {
                try await socket.closeWithError(after: 0.01)
            }

            try await group.waitForAll()
        }

        XCTAssertTrue(openFails.access { $0 })
        XCTAssertTrue(didCloseWithError.access { $0 })
    }

    func testMultipleOpensAndClosesAllFailWithError() async throws {
        let socket = Socket()
        let openCount = Locked(0)
        let closeCount = Locked(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            (0..<50).forEach { _ in
                group.addTask {
                    do {
                        try await socket.waiter.open(timeout: 0.5) { await socket.isOpen }
                        XCTFail()
                    } catch {
                        XCTAssertEqual(
                            WebSocketError.receiveUnknownMessageType,
                            error as? WebSocketError
                        )
                        openCount.access { $0 += 1 }
                    }
                }
            }

            (0..<50).forEach { _ in
                group.addTask {
                    do {
                        try await socket.waiter.close(timeout: 0.5) { await socket.isClosed }
                        XCTFail()
                    } catch {
                        XCTAssertEqual(
                            WebSocketError.receiveUnknownMessageType,
                            error as? WebSocketError
                        )
                        closeCount.access { $0 += 1 }
                    }
                }
            }

            group.addTask {
                try await socket.closeWithError(after: 0.00001)
            }

            try await group.waitForAll()
        }

        XCTAssertEqual(50, openCount.access { $0 })
        XCTAssertEqual(50, closeCount.access { $0 })
    }
}

private actor Socket {
    var isOpen: Bool = false
    var isClosed: Bool = false

    nonisolated let waiter = WebSocketWaiter()

    func open(after delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(NSEC_PER_SEC) * delay))
        isOpen = true
        waiter.didOpen()
    }

    func close(after delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(NSEC_PER_SEC) * delay))
        isClosed = true
        waiter.didClose(error: nil)
    }

    func closeWithError(after delay: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(Double(NSEC_PER_SEC) * delay))
        isClosed = true
        waiter.didClose(error: .receiveUnknownMessageType)
    }
}
