# WebSocket wrapper around `URLSessionWebSocketTask`

## _(macOS, iOS, iPadOS, tvOS, and watchOS)_

A concrete implementation of a WebSocket client implemented by wrapping Apple's [`NWConnection`](https://developer.apple.com/documentation/network/nwconnection).

The public "interface" of `WebSocket` is a simple struct whose public "methods" are exposed as closures. The reason for this design is to make it easy to inject fake `WebSocket`s into your code for testing purposes.

The actual implementation is `SystemWebSocket`, but this type is not publicly accessible. Instead, you can access it via `WebSocket.system(url:)`. `SystemWebSocket` tries its best to mirror the documented behavior of web browsers' [`WebSocket`](http://developer.mozilla.org/en-US/docs/Web/API/WebSocket). Please report any deviations as bugs.

`WebSocket` exposes a simple API, makes heavy use of [Swift Concurrency](https://developer.apple.com/documentation/swift/swift_standard_library/concurrency), and conforms to Apple's Combine [`Publisher`](https://developer.apple.com/documentation/combine/publisher).

## Usage

```swift
// `WebSocket` starts connecting to the specified `URL` immediately.
let socket = WebSocket.system(url: url(49999))

// Wait for `WebSocket` to be ready to send and receive messages.
try await socket.open()

// Send a message to the server
try await socket.send(.text("hello"))

// Receive messages from the server
for await message in socket.messages {
    print(message)
}

try await socket.close()
```

## Tests

1. In your Terminal, navigate to the `websocket-apple` directory
2. Run the tests using `swift test`
