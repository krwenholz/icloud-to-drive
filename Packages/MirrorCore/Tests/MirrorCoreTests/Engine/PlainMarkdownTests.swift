import Foundation
import Testing

@testable import MirrorCore

/// Roots that upload plain `.md` files instead of converting them to Google Docs.
@Suite struct PlainMarkdownTests {
  let harness: EngineHarness

  init() throws { harness = try EngineHarness() }

  private func plainRoot(files: [String: String]) throws -> RootConfig {
    var root = try harness.makeRoot("Notes", files: files)
    root.convertToDocs = false
    return root
  }

  private func mimeType(_ engine: SyncEngine, _ path: String) async throws -> String {
    let mirror = try #require(await engine.mirrorFolderID())
    return try #require(await harness.drive.tree(under: mirror)[path]).file.mimeType
  }

  @Test func plainImportKeepsTheExtensionAndSkipsConversion() async throws {
    defer { harness.cleanUp() }
    let root = try plainRoot(files: ["top.md": "# Top\n", "projects/garden.md": "# Garden\n"])
    let engine = harness.makeEngine()

    let report = await engine.reconcile(root)

    #expect(report.failures.isEmpty)
    #expect(
      try await harness.tree(engine) == [
        "Notes/", "Notes/_sync-status", "Notes/projects/", "Notes/projects/garden.md",
        "Notes/top.md",
      ])
    #expect(try await mimeType(engine, "Notes/top.md") == "text/markdown")
    // The status Doc is for reading, so it is a Doc whatever the root's setting.
    #expect(try await mimeType(engine, "Notes/_sync-status") == DriveFile.docMimeType)
    #expect(try await harness.docs(engine)["Notes/projects/garden.md"] == "# Garden\n")
    #expect(await engine.reconcile(root).applied == 0)
  }

  @Test func plainEditsUpdateInPlaceAndReplaceKeepsThePlainName() async throws {
    defer { harness.cleanUp() }
    let root = try plainRoot(files: ["a.md": "one"])
    for strategy in [UpdateStrategy.inPlace, .replace] {
      let engine = harness.makeEngine(strategy: strategy)
      _ = await engine.reconcile(root)
      try harness.write(root, "a.md", "edited with \(strategy)")
      _ = await engine.reconcile(root)
      #expect(try await harness.docs(engine)["Notes/a.md"] == "edited with \(strategy)")
      #expect(try await mimeType(engine, "Notes/a.md") == "text/markdown")
    }
  }

  @Test func switchingTheSettingBothWaysReplacesEveryFile() async throws {
    defer { harness.cleanUp() }
    // Twenty of twenty files change format, far past the mass-deletion thresholds.
    let files = Dictionary(uniqueKeysWithValues: (0..<20).map { ("n\($0).md", "note \($0)") })
    var root = try harness.makeRoot("Notes", files: files)
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let docIDs = try await (0..<20).asyncMap { try await harness.docID(engine, "Notes/n\($0)") }

    root.convertToDocs = false
    let toPlain = await engine.reconcile(root)

    #expect(toPlain.attention == nil)
    #expect(toPlain.heldDeletions == 0)
    #expect(toPlain.failures.isEmpty)
    #expect(try await harness.docs(engine).count == 21)
    #expect(try await harness.docs(engine)["Notes/n7.md"] == "note 7")
    #expect(try await mimeType(engine, "Notes/n7.md") == "text/markdown")
    for id in docIDs { #expect(await harness.drive.item(id)?.trashed == true) }
    #expect(await engine.reconcile(root).applied == 0)

    let plainIDs = try await (0..<20).asyncMap {
      try await harness.docID(engine, "Notes/n\($0).md")
    }
    root.convertToDocs = true
    let backToDocs = await engine.reconcile(root)

    #expect(backToDocs.attention == nil)
    #expect(try await harness.docs(engine)["Notes/n7"] == "note 7")
    #expect(try await mimeType(engine, "Notes/n7") == DriveFile.docMimeType)
    for id in plainIDs { #expect(await harness.drive.item(id)?.trashed == true) }
    #expect(try await harness.docs(engine).count == 21)
    #expect(await engine.reconcile(root).applied == 0)
  }

  @Test func aFailedFormatSwitchKeepsTheOldCopyAndRetries() async throws {
    defer { harness.cleanUp() }
    var root = try harness.makeRoot("Notes", files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let original = try await harness.docID(engine, "Notes/a")

    root.convertToDocs = false
    await harness.drive.failNext(where: {
      if case .createFile(name: "a.md") = $0 { true } else { false }
    })
    let failed = await engine.reconcile(root)
    #expect(failed.failures.count == 1)
    #expect(await harness.drive.item(original)?.trashed == false)

    #expect(await engine.reconcile(root).failures.isEmpty)
    #expect(await harness.drive.item(original)?.trashed == true)
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/a.md"])
  }

  @Test func rebuildRecoversTheFormatFromTheMimeType() async throws {
    defer { harness.cleanUp() }
    let root = try plainRoot(files: ["a.md": "a", "x/b.md": "b"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let before = try await harness.tree(engine)

    try FileManager.default.removeItem(at: harness.paths.stateFile)
    let restarted = harness.makeEngine()
    let start = await harness.drive.calls.count
    let report = await restarted.reconcile(root)

    // Recovered as plain files, so a plain root has nothing to redo.
    #expect(report.failures.isEmpty)
    #expect(await harness.contentCalls(since: start).isEmpty)
    #expect(try await harness.tree(restarted) == before)

    // The same recovered state under a converting root is replaced, not left mismatched.
    try FileManager.default.removeItem(at: harness.paths.stateFile)
    var converting = root
    converting.convertToDocs = true
    let third = harness.makeEngine()
    _ = await third.reconcile(converting)
    #expect(
      try await harness.tree(third) == [
        "Notes/", "Notes/_sync-status", "Notes/a", "Notes/x/", "Notes/x/b",
      ])
  }

  @Test func movesKeepThePlainName() async throws {
    defer { harness.cleanUp() }
    let root = try plainRoot(files: ["inbox/idea.md": "an idea", "keep.md": "k"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let id = try await harness.docID(engine, "Notes/inbox/idea.md")

    try harness.move(root, "inbox/idea.md", "inbox/better-idea.md")
    _ = await engine.reconcile(root)
    #expect(try await harness.docID(engine, "Notes/inbox/better-idea.md") == id)

    try harness.move(root, "inbox/better-idea.md", "projects/better-idea.md")
    _ = await engine.reconcile(root)
    #expect(try await harness.docID(engine, "Notes/projects/better-idea.md") == id)
    #expect(
      try await harness.tree(engine) == [
        "Notes/", "Notes/_sync-status", "Notes/inbox/", "Notes/keep.md", "Notes/projects/",
        "Notes/projects/better-idea.md",
      ])
    #expect(await harness.drive.item(id)?.file.mimeType == "text/markdown")
  }

  @Test func oldConfigAndStateDecodeAsConverted() throws {
    let root = try JSONDecoder().decode(
      RootConfig.self,
      from: Data(
        #"{"id":"11111111-2222-3333-4444-555555555555","displayName":"Notes","path":"/tmp/n","filter":{"include":["**/*.md"],"exclude":[]}}"#
          .utf8))
    #expect(root.convertToDocs)
    let record = try JSONDecoder().decode(
      FileRecord.self, from: Data(#"{"fileID":"f","contentHash":"h"}"#.utf8))
    #expect(record.converted)
  }
}

extension Sequence {
  fileprivate func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
    var result: [T] = []
    for element in self { result.append(try await transform(element)) }
    return result
  }
}
