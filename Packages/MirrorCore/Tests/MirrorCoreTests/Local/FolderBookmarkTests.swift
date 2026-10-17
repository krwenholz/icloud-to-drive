import Foundation
import Testing

@testable import MirrorCore

@Suite struct FolderBookmarkTests {
  @Test func roundTrips() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let data = try FolderBookmark.create(for: dir.url)
    let resolved = try FolderBookmark.resolve(data)
    #expect(resolved.url.resolvingSymlinksInPath() == dir.url.resolvingSymlinksInPath())
    #expect(!resolved.isStale)
  }

  @Test func findsTheFolderAfterARename() throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let original = dir.url.appendingPathComponent("before")
    let renamed = dir.url.appendingPathComponent("after")
    try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
    let data = try FolderBookmark.create(for: original)
    try FileManager.default.moveItem(at: original, to: renamed)

    let resolved = try FolderBookmark.resolve(data)
    #expect(resolved.url.resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
  }

  @Test func garbageDataThrowsResolutionError() {
    #expect(throws: FolderBookmark.ResolutionError.self) {
      try FolderBookmark.resolve(Data("not a bookmark".utf8))
    }
  }

  @Test func deletedFolderThrowsResolutionError() throws {
    let dir = try TempDirectory()
    let data = try FolderBookmark.create(for: dir.url)
    dir.remove()
    #expect(throws: FolderBookmark.ResolutionError.self) { try FolderBookmark.resolve(data) }
  }
}
