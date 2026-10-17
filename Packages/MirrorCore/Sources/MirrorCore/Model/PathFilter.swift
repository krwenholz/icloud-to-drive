import Foundation

/// A glob over `/`-separated relative paths.
///
/// `*` matches within one path segment, `?` matches one character within a segment, and `**`
/// as a whole segment matches zero or more segments. A pattern ending in `/` matches everything
/// under that directory. Matching ignores case, like the default macOS file system.
public struct GlobPattern: Hashable, Codable, Sendable, CustomStringConvertible {
  public let pattern: String
  private let segments: [String]

  public init(_ pattern: String) {
    self.pattern = pattern
    var normalized = pattern.precomposedStringWithCanonicalMapping.lowercased()
    if normalized.hasSuffix("/") { normalized += "**" }
    segments = normalized.split(separator: "/").map(String.init)
  }

  public init(from decoder: any Decoder) throws {
    self.init(try decoder.singleValueContainer().decode(String.self))
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(pattern)
  }

  public var description: String { pattern }

  public func matches(_ path: String) -> Bool {
    let parts = path.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
    return Self.match(segments[...], parts.map(String.init)[...])
  }

  /// Whether every path under `directory` matches, e.g. `.trash/` or `archive/**`.
  public func matchesEverything(under directory: String) -> Bool {
    guard segments.last == "**" else { return false }
    let parts = directory.precomposedStringWithCanonicalMapping.lowercased().split(separator: "/")
    return Self.match(segments.dropLast(), parts.map(String.init)[...])
  }

  private static func match(_ pattern: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
    guard let head = pattern.first else { return path.isEmpty }
    if head == "**" {
      let rest = pattern.dropFirst()
      return (0...path.count).contains { match(rest, path.dropFirst($0)) }
    }
    guard let segment = path.first, matchSegment(Array(head)[...], Array(segment)[...]) else {
      return false
    }
    return match(pattern.dropFirst(), path.dropFirst())
  }

  private static func matchSegment(_ pattern: ArraySlice<Character>, _ name: ArraySlice<Character>)
    -> Bool
  {
    guard let head = pattern.first else { return name.isEmpty }
    switch head {
    case "*":
      return (0...name.count).contains { matchSegment(pattern.dropFirst(), name.dropFirst($0)) }
    case "?":
      return !name.isEmpty && matchSegment(pattern.dropFirst(), name.dropFirst())
    default:
      return name.first == head && matchSegment(pattern.dropFirst(), name.dropFirst())
    }
  }
}

/// Decides which files under a root are mirrored.
public struct PathFilter: Hashable, Codable, Sendable {
  public var include: [GlobPattern]
  public var exclude: [GlobPattern]

  public static let defaultInclude = [GlobPattern("**/*.md")]
  public static let defaultExclude = [GlobPattern(".trash/"), GlobPattern(".obsidian/")]

  public init(include: [GlobPattern] = defaultInclude, exclude: [GlobPattern] = defaultExclude) {
    self.include = include
    self.exclude = exclude
  }

  /// Hidden files and anything inside a hidden directory are always excluded, whatever the
  /// patterns say. That also covers iCloud's `.name.icloud` placeholders.
  public static func isHidden(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0.hasPrefix(".") }
  }

  public func includes(_ path: RelativePath) -> Bool {
    guard !Self.isHidden(path.value) else { return false }
    guard include.contains(where: { $0.matches(path.value) }) else { return false }
    return !exclude.contains { $0.matches(path.value) }
  }

  /// Whether a directory could still contain included files, so scanning can skip it otherwise.
  public func mayDescend(into directory: String) -> Bool {
    guard !Self.isHidden(directory) else { return false }
    return !exclude.contains { $0.matchesEverything(under: directory) }
  }
}
