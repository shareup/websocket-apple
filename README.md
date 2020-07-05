# WebSocket wrapper around `URLSessionWebSocketTask`

## _(macOS, iOS, iPadOS, tvOS, and watchOS)_

A concrete implementation of a WebSocket client implemented by wrapping Apple's `URLSessionWebSocketTask` and conforming to [`WebSocketProtocol`](https://github.com/shareup/websocket-protocol). `WebSocket` exposes a simple API and conforms to Apple's Combine [`Publisher`](https://developer.apple.com/documentation/combine/publisher).

## Usage

```swift
let socket = WebSocket(url: url(49999))

let sub = socket.sink(
	receiveCompletion: { print("Socket closed: \(String(describing: $0))") },
	receiveValue: { (result) in
		switch result {
		case .success(.open):
			socket.send("First message")
		case .success(.string(let incoming)):
			print("Received \(incoming)")
		case .failure:
			socket.close()
		default:
			break
		}
	}
)
defer { sub.cancel() }

socket.connect()
```

## Tests

1. In your Terminal, navigate to the `websocket-apple` directory
2. Run the tests using `swift test`
