import Foundation

/// Serves canned HTTP responses to a `URLSession` and records the requests it saw.
///
/// Each `HTTPStub` tags its session with a unique header so tests can run in parallel without
/// sharing handlers.
final class HTTPStub: @unchecked Sendable {
  // @unchecked: all mutable state is guarded by `lock`.
  struct Response {
    var status: Int
    var headers: [String: String] = [:]
    var body: Data = Data()

    static func json(_ status: Int, _ json: String, headers: [String: String] = [:]) -> Response {
      Response(
        status: status, headers: headers.merging(["Content-Type": "application/json"]) { $1 },
        body: Data(json.utf8))
    }
  }

  /// A request as received, with the body read from its stream.
  struct Recorded {
    var request: URLRequest
    var body: Data
    var url: URL { request.url! }
    var method: String { request.httpMethod ?? "GET" }
    func header(_ name: String) -> String? { request.value(forHTTPHeaderField: name) }
    var query: [String: String] {
      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
      return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
    }
  }

  fileprivate static let headerName = "X-HTTP-Stub-ID"
  private static let registryLock = NSLock()
  nonisolated(unsafe) private static var registry: [String: HTTPStub] = [:]

  private let id = UUID().uuidString
  private let lock = NSLock()
  private var queued: [Response] = []
  private var handler: (@Sendable (Recorded) -> Response)?
  private var recorded: [Recorded] = []

  let session: URLSession

  init() {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    configuration.httpAdditionalHeaders = [Self.headerName: id]
    session = URLSession(configuration: configuration)
    Self.registryLock.withLock { Self.registry[id] = self }
  }

  deinit {
    Self.registryLock.withLock { _ = Self.registry.removeValue(forKey: id) }
  }

  /// Responses returned in order, one per request. Takes priority over `respond(with:)`.
  func enqueue(_ responses: Response...) {
    lock.withLock { queued += responses }
  }

  /// Computes a response for every request not served from the queue.
  func respond(with handler: @escaping @Sendable (Recorded) -> Response) {
    lock.withLock { self.handler = handler }
  }

  var requests: [Recorded] { lock.withLock { recorded } }

  fileprivate static func stub(for request: URLRequest) -> HTTPStub? {
    guard let id = request.value(forHTTPHeaderField: headerName) else { return nil }
    return registryLock.withLock { registry[id] }
  }

  fileprivate func serve(_ request: URLRequest) -> Response {
    var stripped = request
    stripped.setValue(nil, forHTTPHeaderField: Self.headerName)
    let entry = Recorded(request: stripped, body: Self.body(of: request))
    return lock.withLock {
      recorded.append(entry)
      if !queued.isEmpty { return queued.removeFirst() }
      return handler?(entry) ?? Response.json(599, #"{"error":"no stubbed response"}"#)
    }
  }

  private static func body(of request: URLRequest) -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 16_384)
    while stream.hasBytesAvailable {
      let count = stream.read(&buffer, maxLength: buffer.count)
      guard count > 0 else { break }
      data.append(buffer, count: count)
    }
    return data
  }
}

final class StubURLProtocol: URLProtocol {
  override class func canInit(with request: URLRequest) -> Bool {
    HTTPStub.stub(for: request) != nil
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    guard let stub = HTTPStub.stub(for: request), let url = request.url else {
      client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
      return
    }
    let response = stub.serve(request)
    let http = HTTPURLResponse(
      url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
      headerFields: response.headers)!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: response.body)
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}
