import Foundation

/// A `multipart/related` body: JSON metadata followed by Markdown media.
struct MultipartBody {
  let boundary: String
  let data: Data

  init(metadata: [String: Any], markdown: Data, boundary: String) throws {
    self.boundary = boundary
    let json = try JSONSerialization.data(
      withJSONObject: metadata, options: [.sortedKeys, .withoutEscapingSlashes])
    var body = Data()
    body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n")
    body.append(json)
    body.append("\r\n--\(boundary)\r\nContent-Type: text/markdown; charset=UTF-8\r\n\r\n")
    body.append(markdown)
    body.append("\r\n--\(boundary)--\r\n")
    data = body
  }

  var contentType: String { "multipart/related; boundary=\(boundary)" }
}

extension Data {
  fileprivate mutating func append(_ string: String) { append(Data(string.utf8)) }
}
