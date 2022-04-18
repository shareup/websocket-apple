import Foundation

public typealias WebSocketCloseResult = Result<(code: WebSocketCloseCode, reason: Data?), Error>

internal let normalClosure: WebSocketCloseResult = .success((.normalClosure, nil))
internal let abnormalClosure: WebSocketCloseResult = .success((.abnormalClosure, nil))
internal let closureWithError: (Error) -> WebSocketCloseResult = { e in .failure(e) }
