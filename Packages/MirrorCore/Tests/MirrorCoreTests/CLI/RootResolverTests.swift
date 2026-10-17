import Foundation
import Testing

@testable import MirrorCore

struct RootResolverTests {
  @Test func temporaryIDIsDeterministicWithVersionAndVariantBits() {
    let a = RootResolver.temporaryID(forCanonicalPath: "/Users/me/notes")
    #expect(a == RootResolver.temporaryID(forCanonicalPath: "/Users/me/notes"))
    #expect(a != RootResolver.temporaryID(forCanonicalPath: "/Users/me/other"))
    let text = a.uuidString
    let parts = text.split(separator: "-")
    #expect(parts[2].first == "5")
    #expect("89AB".contains(parts[3].first!))
  }

  @Test func matchesAConfiguredRootThroughSymlinks() throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder(files: ["a.md": "x"])
    let app = RootConfig(
      displayName: "Work Notes", path: folder.path,
      filter: PathFilter(include: [GlobPattern("*.md")]))
    let config = MirrorConfig(roots: [app])

    let link = harness.base.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)

    for path in [folder.path, link.path, folder.path + "/"] {
      let resolved = RootResolver.resolve(path: path, config: config, paths: harness.paths)
      #expect(!resolved.isTemporary)
      #expect(resolved.root == app)
      #expect(resolved.stateFile == harness.paths.stateFile)
    }
  }

  @Test func unknownFoldersBecomeTemporaryRootsWithTheirOwnStateFile() throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder("garden", files: [:])
    let resolved = RootResolver.resolve(
      path: folder.path, config: MirrorConfig(), paths: harness.paths)
    #expect(resolved.isTemporary)
    #expect(resolved.root.displayName == "garden")
    #expect(resolved.root.filter == PathFilter())
    #expect(resolved.root.id == RootResolver.temporaryID(forCanonicalPath: resolved.root.path))
    #expect(resolved.stateFile.lastPathComponent == "mirrorctl-state.json")
    #expect(resolved.stateFile != harness.paths.stateFile)
  }
}
