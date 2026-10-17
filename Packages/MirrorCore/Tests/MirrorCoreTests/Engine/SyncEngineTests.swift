import Foundation
import Testing

@testable import MirrorCore

@Suite struct SyncEngineTests {
  let harness: EngineHarness

  init() throws { harness = try EngineHarness() }

  @Test func initialImportMirrorsNestedTree() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(
      "Notes",
      files: [
        "top.md": "# Top\n", "projects/garden.md": "---\ntags: [x]\n---\n# Garden\n",
        "projects/deep/er.md": "deeper", "notes.txt": "not markdown", ".hidden.md": "nope",
        "empty.md": "",
      ])
    let engine = harness.makeEngine()

    let report = await engine.reconcile(root)

    #expect(report.completed)
    #expect(report.failures.isEmpty)
    #expect(
      try await harness.tree(engine) == [
        "Notes/", "Notes/_sync-status", "Notes/empty", "Notes/projects/",
        "Notes/projects/deep/", "Notes/projects/deep/er", "Notes/projects/garden", "Notes/top",
      ])
    let docs = try await harness.docs(engine)
    #expect(docs["Notes/projects/garden"] == "# Garden\n")
    #expect(docs["Notes/empty"] == "\n")

    let garden = try await harness.drive.item(harness.docID(engine, "Notes/projects/garden"))
    #expect(garden?.file.description == "Notes / projects/garden.md")
    #expect(garden?.file.appProperties["r"] == root.id.uuidString)
    #expect(garden?.file.appProperties["k"] == (try RelativePath("projects/garden.md")).pathHash)
    #expect(garden?.file.appProperties["h"] == Hashing.sha256Hex(Data("# Garden\n".utf8)))

    let second = await engine.reconcile(root)
    #expect(second.applied == 0)
  }

  @Test(arguments: [UpdateStrategy.inPlace, .replace])
  func editUpdatesTheDoc(strategy: UpdateStrategy) async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "one"])
    let engine = harness.makeEngine(strategy: strategy)
    _ = await engine.reconcile(root)
    let originalID = try await harness.docID(engine, "Notes/a")

    try harness.write(root, "a.md", "one, edited")
    let report = await engine.reconcile(root)

    #expect(report.applied == 1)
    #expect(try await harness.docs(engine)["Notes/a"] == "one, edited")
    let newID = try await harness.docID(engine, "Notes/a")
    switch strategy {
    case .inPlace: #expect(newID == originalID)
    case .replace:
      #expect(newID != originalID)
      #expect(await harness.drive.item(originalID)?.trashed == true)
    }
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/a"])
  }

  @Test func touchedButUnchangedFileIsNotUploaded() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "---\nupdated: 1\n---\nsame"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let start = await harness.drive.calls.count

    try harness.write(root, "a.md", "---\nupdated: 2\n---\nsame")
    _ = await engine.reconcile(root)

    #expect(await harness.contentCalls(since: start).isEmpty)
  }

  @Test func renameAndMoveKeepTheFileID() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["inbox/idea.md": "an idea", "keep.md": "k"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let id = try await harness.docID(engine, "Notes/inbox/idea")

    try harness.move(root, "inbox/idea.md", "inbox/better-idea.md")
    _ = await engine.reconcile(root)
    #expect(try await harness.docID(engine, "Notes/inbox/better-idea") == id)

    try harness.move(root, "inbox/better-idea.md", "projects/better-idea.md")
    _ = await engine.reconcile(root)
    #expect(try await harness.docID(engine, "Notes/projects/better-idea") == id)
    let moved = await harness.drive.item(id)
    #expect(moved?.file.description == "Notes / projects/better-idea.md")
    #expect(
      moved?.file.appProperties["k"] == (try RelativePath("projects/better-idea.md")).pathHash)
    #expect(
      try await harness.tree(engine) == [
        "Notes/", "Notes/_sync-status", "Notes/inbox/", "Notes/keep", "Notes/projects/",
        "Notes/projects/better-idea",
      ])
  }

  @Test func deleteTrashesTheDoc() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a", "b.md": "b"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let id = try await harness.docID(engine, "Notes/a")

    try harness.remove(root, "a.md")
    _ = await engine.reconcile(root)

    #expect(await harness.drive.item(id)?.trashed == true)
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/b"])
    #expect(await engine.status(of: root.id).mirroredFiles == 1)
  }

  @Test func massDeletionIsHeldUntilApplied() async throws {
    defer { harness.cleanUp() }
    let files = Dictionary(uniqueKeysWithValues: (0..<20).map { ("n\($0).md", "note \($0)") })
    let root = try harness.makeRoot(files: files)
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)

    for i in 0..<12 { try harness.remove(root, "n\(i).md") }
    let held = await engine.reconcile(root)
    #expect(held.attention == .massDeletion(pending: 12, mirrored: 20))
    #expect(held.heldDeletions == 12)
    #expect(try await harness.docs(engine).count == 21)
    let status = try await harness.docs(engine)["Notes/_sync-status"]
    #expect(status?.contains("Deletions on hold: 12") == true)

    let applied = await engine.reconcile(root, applyPendingDeletions: true)
    #expect(applied.attention == nil)
    #expect(try await harness.docs(engine).count == 9)
  }

  @Test func missingRootTrashesNothing() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)

    try FileManager.default.removeItem(at: root.url)
    let report = await engine.reconcile(root)

    #expect(!report.completed)
    guard case .rootUnavailable = report.attention else {
      Issue.record("expected rootUnavailable, got \(String(describing: report.attention))")
      return
    }
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/a"])
  }

  @Test func failureMidBatchResumesWithoutDuplicates() async throws {
    defer { harness.cleanUp() }
    let files = Dictionary(uniqueKeysWithValues: (0..<8).map { ("n\($0).md", "note \($0)") })
    let root = try harness.makeRoot(files: files)
    await harness.drive.failNext(
      where: { if case .createDoc(name: "n5") = $0 { true } else { false } })
    let engine = harness.makeEngine()

    let first = await engine.reconcile(root)
    #expect(first.failures.keys.map(\.value) == ["n5.md"])
    #expect(await engine.status(of: root.id).failures.count == 1)
    #expect(try await harness.docs(engine).count == 8)  // 7 notes + status

    // A fresh engine stands in for the app restarting after the crash.
    let restarted = harness.makeEngine()
    let second = await restarted.reconcile(root)
    #expect(second.failures.isEmpty)
    #expect(second.applied == 1)
    #expect(try await harness.docs(restarted).count == 9)
    #expect(await restarted.status(of: root.id).failures.isEmpty)
  }

  @Test func transientFailureSucceedsNextTime() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    try harness.write(root, "a.md", "a2")
    await harness.drive.failNext(where: { if case .updateDoc = $0 { true } else { false } })

    let failed = await engine.reconcile(root)
    #expect(failed.failures.count == 1)
    #expect(try await harness.docs(engine)["Notes/a"] == "a")
    let status = try await harness.docs(engine)["Notes/_sync-status"]
    #expect(status?.contains("Failing files: 1") == true)

    let retried = await engine.reconcile(root)
    #expect(retried.failures.isEmpty)
    #expect(try await harness.docs(engine)["Notes/a"] == "a2")
    #expect(
      try await harness.docs(engine)["Notes/_sync-status"]?.contains("Failing files: none") == true)
  }

  @Test func rebuildsStateFromDriveWithoutReuploading() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(
      files: ["a.md": "a", "x/b.md": "b", "x/y/c.md": "c"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let before = try await harness.tree(engine)

    try FileManager.default.removeItem(at: harness.paths.stateFile)
    let restarted = harness.makeEngine()
    let start = await harness.drive.calls.count
    let report = await restarted.reconcile(root)

    #expect(report.failures.isEmpty)
    #expect(await harness.contentCalls(since: start).isEmpty)
    #expect(try await harness.tree(restarted) == before)
    #expect(await restarted.status(of: root.id).mirroredFiles == 3)

    // Size and modification time were recorded on that pass, so the next one reads nothing.
    try harness.write(root, "x/b.md", "b2")
    let edit = await restarted.reconcile(root)
    #expect(edit.applied == 1)
  }

  @Test func rebuildKeepsNewestDuplicateAndTrashesTheOther() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let original = try await harness.docID(engine, "Notes/a")
    let originalItem = try #require(await harness.drive.item(original))
    let duplicate = try await harness.drive.createDoc(
      markdown: Data("a".utf8), name: "a", parentID: originalItem.file.parents[0],
      description: "Notes / a.md", appProperties: originalItem.file.appProperties)

    try FileManager.default.removeItem(at: harness.paths.stateFile)
    let restarted = harness.makeEngine()
    _ = await restarted.reconcile(root)

    #expect(await harness.drive.item(original)?.trashed == true)
    #expect(await harness.drive.item(duplicate.id)?.trashed == false)
    #expect(try await harness.tree(restarted) == ["Notes/", "Notes/_sync-status", "Notes/a"])
  }

  @Test func corruptStateIsSetAsideAndRebuilt() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    _ = await harness.makeEngine().reconcile(root)
    try Data("{not json".utf8).write(to: harness.paths.stateFile)

    let start = await harness.drive.calls.count
    let restarted = harness.makeEngine()
    _ = await restarted.reconcile(root)

    #expect(await harness.contentCalls(since: start).isEmpty)
    #expect(
      FileManager.default.fileExists(
        atPath: harness.paths.stateFile.appendingPathExtension("corrupt").path))
  }

  @Test func twoRootsReconcileConcurrently() async throws {
    defer { harness.cleanUp() }
    let notes = try harness.makeRoot("Notes", files: ["a.md": "a", "sub/b.md": "b"])
    let journal = try harness.makeRoot("Journal", files: ["a.md": "journal a"])
    let engine = harness.makeEngine()

    async let first = engine.reconcile(notes)
    async let second = engine.reconcile(journal)
    let reports = await [first, second]

    #expect(reports.allSatisfy { $0.completed })
    #expect(
      try await harness.tree(engine) == [
        "Journal/", "Journal/_sync-status", "Journal/a", "Notes/", "Notes/_sync-status",
        "Notes/a", "Notes/sub/", "Notes/sub/b",
      ])
    #expect(try await harness.docs(engine)["Journal/a"] == "journal a")
  }

  @Test func sameRootReconcilesSerially() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    async let first = engine.reconcile(root)
    async let second = engine.reconcile(root)
    _ = await [first, second]
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/a"])
  }

  @Test(arguments: [true, false])
  func removingRoot(trashDriveFolder: Bool) async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)

    try await engine.removeRoot(root.id, trashDriveFolder: trashDriveFolder)

    #expect(
      await engine.status(of: root.id)
        == RootStatus(
          mirroredFiles: 0, lastSuccessfulSync: nil, failures: [:], driveFolderID: nil))
    let state = try #require(
      {
        if case .loaded(let s) = JSONFileStore<MirrorState>(url: harness.paths.stateFile).load() {
          s
        } else {
          nil
        }
      }())
    #expect(state.roots[root.id.uuidString] == nil)
    #expect(
      try await harness.tree(engine)
        == (trashDriveFolder ? [] : ["Notes/", "Notes/_sync-status", "Notes/a"]))
  }

  @Test func notDownloadedFilesAreDeferred() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a", "cloud.md": "c"])
    let engine = harness.makeEngine(reader: PartiallyDownloadedReader(pending: ["cloud.md"]))

    let report = await engine.reconcile(root)

    #expect(report.deferred.map(\.value) == ["cloud.md"])
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/a"])
    let status = try await harness.docs(engine)["Notes/_sync-status"]
    #expect(status?.contains("Waiting for iCloud to download: 1") == true)
  }

  @Test func statusDocRefreshesHourlyWhenIdle() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "a"])
    let engine = harness.makeEngine()
    _ = await engine.reconcile(root)
    let statusID = try await harness.docID(engine, "Notes/_sync-status")
    func statusUpdates() async -> Int {
      await harness.drive.calls.filter { $0 == .updateDoc(id: statusID) }.count
    }

    harness.clock.advance(by: 30 * 60)
    _ = await engine.reconcile(root)
    #expect(await statusUpdates() == 0)

    harness.clock.advance(by: 31 * 60)
    _ = await engine.reconcile(root)
    #expect(await statusUpdates() == 1)
    let status = try await harness.docs(engine)["Notes/_sync-status"]
    #expect(status?.contains("Mirrored files: 1") == true)
    #expect(status?.contains("2027-01-15T09:01:00Z") == true)
  }

  @Test func capsConcurrentDriveRequests() async throws {
    defer { harness.cleanUp() }
    let files = Dictionary(uniqueKeysWithValues: (0..<12).map { ("n\($0).md", "note \($0)") })
    let root = try harness.makeRoot(files: files)
    let slow = ConcurrencyProbeDrive(base: harness.drive)
    let engine = harness.makeEngine(drive: slow, maxConcurrentRequests: 3)

    _ = await engine.reconcile(root)

    // The upper bound is the guarantee; how close it gets depends on scheduling.
    let peak = await slow.maxInFlight
    #expect(peak >= 1 && peak <= 3)
    #expect(try await harness.docs(engine).count == 13)
  }
}

/// Holds each request open briefly and records the peak number in flight.
actor ConcurrencyProbeDrive: DriveClient {
  let base: InMemoryDriveClient
  private(set) var maxInFlight = 0
  private var inFlight = 0

  init(base: InMemoryDriveClient) { self.base = base }

  private func track<T: Sendable>(_ work: @Sendable () async throws -> T) async rethrows -> T {
    inFlight += 1
    maxInFlight = max(maxInFlight, inFlight)
    defer { inFlight -= 1 }
    for _ in 0..<20 { await Task.yield() }
    return try await work()
  }

  func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) async throws -> DriveFile {
    try await track {
      try await base.createFolder(
        name: name, parentID: parentID, description: description, appProperties: appProperties)
    }
  }
  func createDoc(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String]
  ) async throws -> DriveFile {
    try await track {
      try await base.createDoc(
        markdown: markdown, name: name, parentID: parentID, description: description,
        appProperties: appProperties)
    }
  }
  func updateDoc(id: String, markdown: Data, description: String, appProperties: [String: String])
    async throws -> DriveFile
  {
    try await track {
      try await base.updateDoc(
        id: id, markdown: markdown, description: description, appProperties: appProperties)
    }
  }
  func moveFile(
    id: String, name: String?, description: String?, appProperties: [String: String]?,
    addParent: String?, removeParent: String?
  ) async throws -> DriveFile {
    try await track {
      try await base.moveFile(
        id: id, name: name, description: description, appProperties: appProperties,
        addParent: addParent, removeParent: removeParent)
    }
  }
  func trashFile(id: String) async throws { try await track { try await base.trashFile(id: id) } }
  func listFiles(appProperty key: String, value: String) async throws -> [DriveFile] {
    try await track { try await base.listFiles(appProperty: key, value: value) }
  }
  func userEmail() async throws -> String? { try await track { try await base.userEmail() } }
}
