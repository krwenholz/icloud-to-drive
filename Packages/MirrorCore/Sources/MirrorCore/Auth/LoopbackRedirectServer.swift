import Foundation
import Network

/// One-shot HTTP listener on 127.0.0.1 that catches Google's redirect after the owner approves.
actor LoopbackRedirectServer {
  struct Callback: Equatable {
    var code: String?
    var state: String?
    var error: String?
  }

  static let successPage = page(
    title: "Signed in", message: "You can close this tab and return to \(AppIdentity.displayName).")
  static let failurePage = page(
    title: "Sign-in failed",
    message: "Return to \(AppIdentity.displayName) and try signing in again.")

  private let listener: NWListener
  private let queue = DispatchQueue(label: "dev.krw.DriveMirror.loopback")
  private var acceptTask: Task<Void, Never>?
  private var connectionFeed: AsyncStream<NWConnection>.Continuation?
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  private var expectedState: String?
  /// A redirect that arrived before `waitForCode` said which state to expect.
  private var parked: (callback: Callback, connection: NWConnection)?
  private var outcome: Result<String, any Error>?
  private var waiter: CheckedContinuation<String, any Error>?

  init() throws {
    let parameters = NWParameters.tcp
    // Loopback only: the redirect carries an authorization code.
    parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
    do { listener = try NWListener(using: parameters) } catch {
      throw AuthError.listenerFailed(error.localizedDescription)
    }
  }

  /// Starts listening and returns the port the OS picked.
  func start() async throws -> Int {
    let (states, stateFeed) = AsyncStream<NWListener.State>.makeStream()
    let (incoming, connectionFeed) = AsyncStream<NWConnection>.makeStream()
    self.connectionFeed = connectionFeed
    listener.stateUpdateHandler = { stateFeed.yield($0) }
    listener.newConnectionHandler = { connectionFeed.yield($0) }
    listener.start(queue: queue)

    for await state in states {
      switch state {
      case .ready:
        guard let port = listener.port?.rawValue else {
          throw AuthError.listenerFailed("no port assigned")
        }
        acceptTask = Task {
          for await connection in incoming {
            // Browsers open speculative connections that never send anything, so each
            // connection gets its own task rather than blocking the queue.
            Task { await self.handle(connection) }
          }
        }
        return Int(port)
      case .failed(let error):
        throw AuthError.listenerFailed(error.localizedDescription)
      case .cancelled:
        throw AuthError.listenerFailed("listener cancelled")
      default:
        continue
      }
    }
    throw AuthError.listenerFailed("listener stopped before becoming ready")
  }

  /// Waits for the redirect and returns the authorization code.
  func waitForCode(expectedState: String, timeout: Duration = .seconds(300)) async throws -> String
  {
    self.expectedState = expectedState
    if let parked {
      self.parked = nil
      process(parked.callback, on: parked.connection)
    }
    let timer = Task {
      try await Task.sleep(for: timeout)
      self.finish(.failure(AuthError.signInTimedOut))
    }
    defer { timer.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        if let outcome {
          continuation.resume(with: outcome)
        } else {
          waiter = continuation
        }
      }
    } onCancel: {
      Task { await self.finish(.failure(CancellationError())) }
    }
  }

  func stop() {
    finish(.failure(CancellationError()))
    acceptTask?.cancel()
    connectionFeed?.finish()
    listener.cancel()
    for connection in connections.values { connection.cancel() }
    connections = [:]
  }

  /// Pure decision about a redirect, separate from the socket so it's easy to test.
  static func evaluate(_ callback: Callback, expectedState: String) -> Result<String, AuthError> {
    if let error = callback.error {
      return .failure(error == "access_denied" ? .accessDenied : .authorizationFailed(error))
    }
    guard callback.state == expectedState else { return .failure(.stateMismatch) }
    guard let code = callback.code, !code.isEmpty else {
      return .failure(.missingAuthorizationCode)
    }
    return .success(code)
  }

  /// Returns nil for requests that aren't the OAuth redirect (favicon, probes).
  static func parseCallback(requestHead: String) -> Callback? {
    let parts = requestHead.prefix(while: { $0 != "\r" && $0 != "\n" }).split(separator: " ")
    guard parts.count >= 2, parts[0] == "GET",
      let components = URLComponents(string: String(parts[1])), components.path == "/"
    else { return nil }
    let items = components.queryItems ?? []
    func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
    let callback = Callback(code: value("code"), state: value("state"), error: value("error"))
    return callback.code == nil && callback.error == nil ? nil : callback
  }

  private func handle(_ connection: NWConnection) async {
    connections[ObjectIdentifier(connection)] = connection
    connection.start(queue: queue)
    guard let head = await readRequestHead(connection) else {
      connection.cancel()
      return
    }
    guard let callback = Self.parseCallback(requestHead: head), outcome == nil else {
      respond(on: connection, status: "404 Not Found", body: "")
      return
    }
    if expectedState == nil {
      parked = (callback, connection)
    } else {
      process(callback, on: connection)
    }
  }

  private func process(_ callback: Callback, on connection: NWConnection) {
    guard let expectedState else { return }
    let result = Self.evaluate(callback, expectedState: expectedState)
    switch result {
    case .success:
      respond(on: connection, status: "200 OK", body: Self.successPage)
    case .failure:
      respond(on: connection, status: "400 Bad Request", body: Self.failurePage)
    }
    finish(result.mapError { $0 as any Error })
  }

  private func finish(_ result: Result<String, any Error>) {
    guard outcome == nil else { return }
    outcome = result
    waiter?.resume(with: result)
    waiter = nil
  }

  private func readRequestHead(_ connection: NWConnection) async -> String? {
    var buffer = Data()
    let terminator = Data("\r\n\r\n".utf8)
    while buffer.count < 16_384 {
      guard let (chunk, isComplete) = await receive(connection) else { return nil }
      buffer.append(chunk)
      if buffer.range(of: terminator) != nil { break }
      if isComplete { break }
    }
    return buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self)
  }

  private func receive(_ connection: NWConnection) async -> (Data, Bool)? {
    await withCheckedContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
        data, _, isComplete, error in
        continuation.resume(returning: error == nil ? (data ?? Data(), isComplete) : nil)
      }
    }
  }

  private func respond(on connection: NWConnection, status: String, body: String) {
    let payload = Data(body.utf8)
    let head =
      "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
      + "Content-Length: \(payload.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
    connection.send(
      content: Data(head.utf8) + payload, contentContext: .finalMessage, isComplete: true,
      completion: .contentProcessed { _ in connection.cancel() })
  }

  private static func page(title: String, message: String) -> String {
    """
    <!doctype html><html><head><meta charset="utf-8"><title>\(title)</title>
    <style>body{font:16px -apple-system,sans-serif;text-align:center;margin-top:20vh}</style>
    </head><body><h1>\(title)</h1><p>\(message)</p></body></html>
    """
  }
}
