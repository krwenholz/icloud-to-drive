import Foundation

/// The exact bytes uploaded for a Markdown file, plus their hash.
///
/// Hashing the prepared bytes rather than the raw file means a change that only touches front
/// matter doesn't trigger a re-upload.
public struct PreparedContent: Equatable, Sendable {
  public let data: Data
  public let hash: String

  public init(markdown raw: Data) {
    var text = String(decoding: raw, as: UTF8.self)
    text = Self.strippingFrontMatter(text)
    // Drive may reject a completely empty body for conversion.
    if text.isEmpty { text = "\n" }
    data = Data(text.utf8)
    hash = Hashing.sha256Hex(data)
  }

  /// Removes a leading YAML block: a first line of `---` up to the next `---` or `...` line.
  /// Without a closing line nothing is stripped, since that's just a horizontal rule.
  static func strippingFrontMatter(_ text: String) -> String {
    var body = Substring(text)
    if body.hasPrefix("\u{FEFF}") { body = body.dropFirst() }
    var cursor = body.startIndex
    // `\r\n` is a single Character in Swift, so split on `isNewline` rather than "\n".
    func nextLine() -> Substring? {
      guard cursor < body.endIndex else { return nil }
      let end = body[cursor...].firstIndex(where: \.isNewline) ?? body.endIndex
      let line = body[cursor..<end]
      cursor = end < body.endIndex ? body.index(after: end) : end
      return line
    }
    guard let first = nextLine(), isFence(first, allowDots: false) else { return text }
    while let line = nextLine() {
      if isFence(line, allowDots: true) { return String(body[cursor...]) }
    }
    return text
  }

  private static func isFence(_ line: Substring, allowDots: Bool) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed == "---" || (allowDots && trimmed == "...")
  }
}
