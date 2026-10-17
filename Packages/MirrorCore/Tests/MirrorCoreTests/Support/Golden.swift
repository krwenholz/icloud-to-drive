import Foundation
import Testing

/// Compares text against `Fixtures/Golden/<name>.txt`. Run with `UPDATE_GOLDEN=1` to rewrite
/// the fixtures after an intended change, then review the diff.
enum Golden {
  static let directory = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .appending(path: "Fixtures/Golden")

  static func check(
    _ actual: String, named name: String, sourceLocation: SourceLocation = #_sourceLocation
  )
    throws
  {
    let url = directory.appending(path: "\(name).txt")
    if ProcessInfo.processInfo.environment["UPDATE_GOLDEN"] == "1" {
      try actual.write(to: url, atomically: true, encoding: .utf8)
      return
    }
    let expected = try String(contentsOf: url, encoding: .utf8)
    #expect(actual == expected, "golden \(name) differs", sourceLocation: sourceLocation)
  }

  /// Renders a request as method, URL without query, decoded query parameters, the headers that
  /// matter, and the body.
  static func render(_ recorded: HTTPStub.Recorded) -> String {
    var components = URLComponents(url: recorded.url, resolvingAgainstBaseURL: false)!
    let query = recorded.query.sorted { $0.key < $1.key }.map { "  \($0.key)=\($0.value)" }
    components.query = nil
    let headers = ["Authorization", "Content-Type"].compactMap { name in
      recorded.header(name).map { "  \(name): \($0)" }
    }
    return
      ([
        "\(recorded.method) \(components.url!.absoluteString)", "query:",
      ] + query + ["headers:"] + headers + [
        "body:", String(decoding: recorded.body, as: UTF8.self),
      ])
      .joined(separator: "\n")
  }
}
