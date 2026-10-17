import Foundation

/// `DriveClient` over the Drive v3 REST API.
public final class GoogleDriveClient: DriveClient {
  static let apiBase = "https://www.googleapis.com/drive/v3"
  static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
  /// Only what `DriveFile` holds, to keep responses small.
  static let fileFields = "id,name,mimeType,parents,description,appProperties,modifiedTime"

  private let session: URLSession
  private let tokens: any AccessTokenProvider
  private let retry: RetryPolicy
  private let makeBoundary: @Sendable () -> String

  public init(
    tokens: any AccessTokenProvider,
    session: URLSession = .shared,
    retry: RetryPolicy = RetryPolicy(),
    makeBoundary: @escaping @Sendable () -> String = { "drive-mirror-\(UUID().uuidString)" }
  ) {
    self.tokens = tokens
    self.session = session
    self.retry = retry
    self.makeBoundary = makeBoundary
  }

  // MARK: - DriveClient

  public func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) async throws -> DriveFile {
    var metadata: [String: Any] = [
      "name": name, "mimeType": DriveFile.folderMimeType, "appProperties": appProperties,
    ]
    if let parentID { metadata["parents"] = [parentID] }
    if let description { metadata["description"] = description }
    return try await sendFile(
      method: "POST", url: Self.url("\(Self.apiBase)/files", ["fields": Self.fileFields]),
      json: metadata)
  }

  public func createDoc(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String]
  ) async throws -> DriveFile {
    let metadata: [String: Any] = [
      "name": name, "mimeType": DriveFile.docMimeType, "parents": [parentID],
      "description": description, "appProperties": appProperties,
    ]
    let url = Self.url(
      "\(Self.uploadBase)/files", ["uploadType": "multipart", "fields": Self.fileFields])
    return try await sendMultipart(method: "POST", url: url, metadata: metadata, markdown: markdown)
  }

  public func updateDoc(
    id: String, markdown: Data, description: String, appProperties: [String: String]
  ) async throws -> DriveFile {
    let metadata: [String: Any] = ["description": description, "appProperties": appProperties]
    let url = Self.url(
      "\(Self.uploadBase)/files/\(Self.escapePath(id))",
      ["uploadType": "multipart", "fields": Self.fileFields])
    return try await sendMultipart(
      method: "PATCH", url: url, metadata: metadata, markdown: markdown)
  }

  public func moveFile(id: String, name: String?, addParent: String?, removeParent: String?)
    async throws -> DriveFile
  {
    var query = ["fields": Self.fileFields]
    if let addParent { query["addParents"] = addParent }
    if let removeParent { query["removeParents"] = removeParent }
    var metadata: [String: Any] = [:]
    if let name { metadata["name"] = name }
    return try await sendFile(
      method: "PATCH", url: Self.url("\(Self.apiBase)/files/\(Self.escapePath(id))", query),
      json: metadata)
  }

  public func trashFile(id: String) async throws {
    _ = try await sendFile(
      method: "PATCH",
      url: Self.url("\(Self.apiBase)/files/\(Self.escapePath(id))", ["fields": Self.fileFields]),
      json: ["trashed": true])
  }

  public func listFiles(appProperty key: String, value: String) async throws -> [DriveFile] {
    let q =
      "appProperties has { key='\(Self.escapeQuery(key))' and value='\(Self.escapeQuery(value))' }"
      + " and trashed=false"
    var files: [DriveFile] = []
    var pageToken: String?
    repeat {
      var query = [
        "q": q, "pageSize": "1000", "spaces": "drive",
        "fields": "nextPageToken,files(\(Self.fileFields))",
      ]
      if let pageToken { query["pageToken"] = pageToken }
      let data = try await send(method: "GET", url: Self.url("\(Self.apiBase)/files", query))
      let page = try Self.decode(FileList.self, from: data)
      files += page.files.map(\.driveFile)
      pageToken = page.nextPageToken
    } while pageToken != nil
    return files
  }

  public func userEmail() async throws -> String? {
    let url = Self.url("\(Self.apiBase)/about", ["fields": "user(emailAddress)"])
    do {
      let data = try await send(method: "GET", url: url)
      return try Self.decode(About.self, from: data).user?.emailAddress
    } catch DriveError.http {
      // `drive.file` may not grant access to `about`; that's "signed in", not an error.
      return nil
    }
  }

  // MARK: - Probe helpers (not needed by the engine)

  public func getFile(id: String) async throws -> DriveFile {
    let url = Self.url(
      "\(Self.apiBase)/files/\(Self.escapePath(id))", ["fields": Self.fileFields])
    return try Self.decode(FileResource.self, from: try await send(method: "GET", url: url))
      .driveFile
  }

  /// Exports a Google Doc back to Markdown, to eyeball conversion quality.
  public func exportMarkdown(id: String) async throws -> String {
    let url = Self.url(
      "\(Self.apiBase)/files/\(Self.escapePath(id))/export", ["mimeType": "text/markdown"])
    return String(decoding: try await send(method: "GET", url: url), as: UTF8.self)
  }

  // MARK: - Requests

  private func sendFile(method: String, url: URL, json: [String: Any]) async throws -> DriveFile {
    let body = try JSONSerialization.data(
      withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes])
    let data = try await send(
      method: method, url: url, body: body, contentType: "application/json; charset=UTF-8")
    return try Self.decode(FileResource.self, from: data).driveFile
  }

  private func sendMultipart(method: String, url: URL, metadata: [String: Any], markdown: Data)
    async throws -> DriveFile
  {
    let multipart = try MultipartBody(
      metadata: metadata, markdown: markdown, boundary: makeBoundary())
    let data = try await send(
      method: method, url: url, body: multipart.data, contentType: multipart.contentType)
    return try Self.decode(FileResource.self, from: data).driveFile
  }

  /// Sends one request, refreshing the token once on 401 and backing off on rate limits,
  /// 5xx responses, and transient network errors.
  private func send(method: String, url: URL, body: Data? = nil, contentType: String? = nil)
    async throws -> Data
  {
    var attempt = 1
    var refreshedToken = false
    while true {
      var request = URLRequest(url: url)
      request.httpMethod = method
      request.httpBody = body
      if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
      let token = try await tokens.accessToken()
      request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

      let data: Data
      let response: URLResponse
      do {
        (data, response) = try await session.data(for: request)
      } catch let error as URLError {
        guard RetryPolicy.isRetryable(error), attempt < retry.maxAttempts else {
          throw DriveError.transport(code: error.code.rawValue, message: error.localizedDescription)
        }
        try await retry.sleep(retry.delay(beforeRetry: attempt, retryAfter: nil))
        attempt += 1
        continue
      }

      guard let http = response as? HTTPURLResponse else {
        throw DriveError.invalidResponse("not an HTTP response")
      }
      if (200..<300).contains(http.statusCode) { return data }

      let failure = Self.decodeError(data)
      if http.statusCode == 401 && !refreshedToken {
        refreshedToken = true
        await tokens.invalidateAccessToken()
        continue
      }
      if RetryPolicy.isRetryable(status: http.statusCode, reason: failure.reason),
        attempt < retry.maxAttempts
      {
        let retryAfter = RetryPolicy.parseRetryAfter(http.value(forHTTPHeaderField: "Retry-After"))
        try await retry.sleep(retry.delay(beforeRetry: attempt, retryAfter: retryAfter))
        attempt += 1
        continue
      }
      throw DriveError.http(
        status: http.statusCode, reason: failure.reason, message: failure.message)
    }
  }

  // MARK: - Encoding

  static func url(_ base: String, _ query: [String: String]) -> URL {
    guard !query.isEmpty else { return URL(string: base)! }
    let encoded = query.sorted { $0.key < $1.key }
      .map { "\(escapeComponent($0.key))=\(escapeComponent($0.value))" }
      .joined(separator: "&")
    return URL(string: "\(base)?\(encoded)")!
  }

  /// Percent-encodes everything but RFC 3986 unreserved characters. `URLComponents` leaves `+`
  /// alone, which servers may read as a space.
  static func escapeComponent(_ value: String) -> String {
    let unreserved = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    return value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
  }

  static func escapePath(_ id: String) -> String { escapeComponent(id) }

  /// Escapes a value for a single-quoted string in a Drive `q` expression.
  static func escapeQuery(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
  }

  // MARK: - Decoding

  private struct FileResource: Decodable {
    var id: String
    var name: String?
    var mimeType: String?
    var parents: [String]?
    var description: String?
    var appProperties: [String: String]?
    var modifiedTime: String?

    var driveFile: DriveFile {
      DriveFile(
        id: id, name: name ?? "", mimeType: mimeType ?? "", parents: parents ?? [],
        description: description, appProperties: appProperties ?? [:],
        modifiedTime: modifiedTime.flatMap(GoogleDriveClient.parseDate))
    }
  }

  private struct FileList: Decodable {
    var files: [FileResource]
    var nextPageToken: String?
  }

  private struct About: Decodable {
    struct User: Decodable { var emailAddress: String? }
    var user: User?
  }

  private struct ErrorEnvelope: Decodable {
    struct Body: Decodable {
      struct Item: Decodable { var reason: String? }
      var message: String?
      var errors: [Item]?
    }
    var error: Body
  }

  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw DriveError.invalidResponse("could not decode \(type): \(error)")
    }
  }

  private static func decodeError(_ data: Data) -> (reason: String?, message: String?) {
    guard let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) else {
      return (nil, data.isEmpty ? nil : String(decoding: data.prefix(500), as: UTF8.self))
    }
    return (envelope.error.errors?.first?.reason, envelope.error.message)
  }

  static func parseDate(_ string: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: string) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: string)
  }
}
