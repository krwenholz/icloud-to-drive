import Foundation

/// A file's path within its root, normalized to Unicode NFC.
///
/// macOS can store names decomposed (NFD) while Drive stores them composed (NFC), so every path
/// is normalized on the way in. Otherwise the same file would look like two different files.
public struct RelativePath: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
  public let value: String

  public enum ValidationError: Error, Equatable {
    case empty
    case absolute
    case escapesRoot
    case emptyComponent
  }

  public init(_ raw: String) throws(ValidationError) {
    let normalized = raw.precomposedStringWithCanonicalMapping
    guard !normalized.isEmpty else { throw .empty }
    guard !normalized.hasPrefix("/") else { throw .absolute }
    let components = normalized.split(separator: "/", omittingEmptySubsequences: false)
    for component in components {
      if component == ".." { throw .escapesRoot }
      if component.isEmpty || component == "." { throw .emptyComponent }
    }
    value = normalized
  }

  public init(from decoder: any Decoder) throws {
    let raw = try decoder.singleValueContainer().decode(String.self)
    try self.init(raw)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(value)
  }

  public var description: String { value }

  public static func < (lhs: RelativePath, rhs: RelativePath) -> Bool { lhs.value < rhs.value }

  public var components: [String] { value.split(separator: "/").map(String.init) }

  public var fileName: String { components.last ?? value }

  /// The containing directory relative to the root; empty for files at the root.
  public var directory: String { components.dropLast().joined(separator: "/") }

  /// SHA-256 of the path, stored in the `k` appProperty for lookups.
  public var pathHash: String { Hashing.sha256Hex(value) }

  /// The Google Doc's name: the file name without its `.md` extension.
  public var docTitle: String {
    let name = fileName
    guard name.lowercased().hasSuffix(".md"), name.count > 3 else { return name }
    return String(name.dropLast(3))
  }

  /// The name of this file's Drive copy: a converted Doc drops `.md`, a plain file keeps it.
  public func driveName(converted: Bool) -> String { converted ? docTitle : fileName }

  /// The Doc description that records where it came from, e.g. `Notes / projects/garden.md`.
  public func docDescription(rootName: String) -> String {
    "\(rootName) / \(value)"
  }

  /// Recovers the relative path from a description written by `docDescription(rootName:)`.
  public static func fromDocDescription(_ description: String, rootName: String) -> RelativePath? {
    let prefix = "\(rootName) / "
    guard description.hasPrefix(prefix) else { return nil }
    return try? RelativePath(String(description.dropFirst(prefix.count)))
  }
}

/// Every ancestor directory of a directory path, shallowest first: `a/b/c` → `a`, `a/b`, `a/b/c`.
func directoryAndAncestors(_ directory: String) -> [String] {
  guard !directory.isEmpty else { return [] }
  let parts = directory.split(separator: "/")
  return (1...parts.count).map { parts.prefix($0).joined(separator: "/") }
}

func parentDirectory(of directory: String) -> String {
  guard let slash = directory.lastIndex(of: "/") else { return "" }
  return String(directory[..<slash])
}

extension RelativePath: CodingKeyRepresentable {
  public var codingKey: any CodingKey { PathKey(stringValue: value) }

  public init?<T: CodingKey>(codingKey: T) {
    try? self.init(codingKey.stringValue)
  }

  private struct PathKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
  }
}
