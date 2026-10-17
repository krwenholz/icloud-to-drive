import Foundation
import Testing

@testable import MirrorCore

@Suite struct FileScannerTests {
  private func paths(_ outcome: ScanOutcome) -> [String] {
    guard case .files(let files) = outcome else { return ["<unavailable>"] }
    return files.map(\.path.value)
  }

  @Test func scansNestedFoldersSortedWithSizeAndModified() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("b.md", "12345")
    try dir.write("a/deep/c.md")
    try dir.write("a/a.md")
    try dir.write("notes.txt")

    let outcome = FileScanner().scan(root: dir.url, filter: PathFilter())
    #expect(paths(outcome) == ["a/a.md", "a/deep/c.md", "b.md"])
    guard case .files(let files) = outcome else { return }
    let b = try #require(files.first { $0.path.value == "b.md" })
    #expect(b.size == 5)
    #expect(abs(b.modified.timeIntervalSinceNow) < 60)
  }

  @Test func appliesExcludePatterns() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("keep.md")
    try dir.write("drafts/skip.md")
    try dir.write("other.md")

    let filter = PathFilter(exclude: [GlobPattern("drafts/"), GlobPattern("other.md")])
    #expect(paths(FileScanner().scan(root: dir.url, filter: filter)) == ["keep.md"])
  }

  @Test func skipsHiddenFilesAndDirectories() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("visible.md")
    try dir.write(".hidden.md")
    try dir.write(".secret/inside.md")
    try dir.write("sub/.also-hidden.md")

    #expect(paths(FileScanner().scan(root: dir.url, filter: PathFilter())) == ["visible.md"])
  }

  @Test func skipsSymlinkedFilesAndDirectories() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("real/a.md")
    let outside = try TempDirectory()
    defer { outside.remove() }
    let target = try outside.write("target.md")
    try FileManager.default.createSymbolicLink(
      at: dir.url.appendingPathComponent("link.md"), withDestinationURL: target)
    try FileManager.default.createSymbolicLink(
      at: dir.url.appendingPathComponent("linkdir"), withDestinationURL: outside.url)

    #expect(paths(FileScanner().scan(root: dir.url, filter: PathFilter())) == ["real/a.md"])
  }

  @Test func skipsPackageContents() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("Thing.app/Contents/foo.md")
    try dir.write("plain.md")
    // Guards the premise: if LaunchServices stopped treating .app as a package this would
    // otherwise pass for the wrong reason.
    let isPackage = try dir.url.appendingPathComponent("Thing.app")
      .resourceValues(forKeys: [.isPackageKey]).isPackage
    #expect(isPackage == true)

    #expect(paths(FileScanner().scan(root: dir.url, filter: PathFilter())) == ["plain.md"])
  }

  @Test func missingRootIsUnavailable() {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
    guard case .unavailable = FileScanner().scan(root: missing, filter: PathFilter()) else {
      Issue.record("expected unavailable")
      return
    }
  }

  @Test func fileAsRootIsUnavailable() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let file = try dir.write("a.md")
    guard case .unavailable = FileScanner().scan(root: file, filter: PathFilter()) else {
      Issue.record("expected unavailable")
      return
    }
  }

  @Test func unreadableRootIsUnavailable() throws {
    let dir = try TempDirectory()
    defer {
      try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.url.path)
      dir.remove()
    }
    try dir.write("a.md")
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: dir.url.path)
    // Running as root would ignore the mode bits.
    try #require(!FileManager.default.isReadableFile(atPath: dir.url.path))
    guard case .unavailable = FileScanner().scan(root: dir.url, filter: PathFilter()) else {
      Issue.record("expected unavailable")
      return
    }
  }

  @Test func emptyRootIsEmptyFiles() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    #expect(FileScanner().scan(root: dir.url, filter: PathFilter()) == .files([]))
  }

  @Test func normalizesNFDNamesToNFC() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("cafe\u{0301}.md")
    let found = paths(FileScanner().scan(root: dir.url, filter: PathFilter()))
    #expect(found == ["caf\u{00E9}.md"])
    #expect(found.first?.unicodeScalars.count == 7)
  }

  @Test func relativePathsSurviveSymlinkedRootSpelling() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    try dir.write("x/y.md")
    // Temp dirs live under /var, a symlink to /private/var; scan via the spelling that isn't
    // the real one.
    let alternate = URL(fileURLWithPath: "/private" + dir.url.resolvingSymlinksInPath().path)
    let root = FileManager.default.fileExists(atPath: alternate.path) ? alternate : dir.url
    #expect(paths(FileScanner().scan(root: root, filter: PathFilter())) == ["x/y.md"])
  }
}
