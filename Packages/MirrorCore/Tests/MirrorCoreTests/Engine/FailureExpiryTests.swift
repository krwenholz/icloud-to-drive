import Foundation
import Testing

@testable import MirrorCore

/// Failures stop being shown, and files stop being retried, once they are a month old and the
/// file hasn't changed. All time here is the harness clock; nothing sleeps.
@Suite struct FailureExpiryTests {
  let harness: EngineHarness
  let reader = ScriptedReader()
  static let day: TimeInterval = 24 * 60 * 60

  init() throws { harness = try EngineHarness() }

  private func status(_ engine: SyncEngine, _ root: RootConfig) async -> RootStatus {
    await engine.status(of: root.id)
  }

  private func statusDoc(_ engine: SyncEngine) async throws -> String {
    try #require(try await harness.docs(engine)["Notes/_sync-status"])
  }

  @Test func recordsWhenAFailureStartedAndKeepsItWhileTheProblemLasts() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x", "ok.md": "ok"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    let started = harness.clock.now

    _ = await engine.reconcile(root)
    harness.clock.advance(by: 2 * Self.day)
    _ = await engine.reconcile(root)

    let failure = try #require(await status(engine, root).failures[try RelativePath("bad.md")])
    #expect(failure.firstSeen == started)
    #expect(failure.lastSeen == harness.clock.now)
    #expect(failure.message.contains("simulated read failure"))
    #expect(failure.size == 1)
    let doc = try await statusDoc(engine)
    #expect(
      doc.contains("`bad.md`: Couldn't read the file: simulated read failure (since Jan 15, 2027)"))
  }

  @Test func expiredFailuresAreHiddenAndTheFileIsNotRetried() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x", "ok.md": "ok"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)

    // Still a problem at 29 days: retried, shown, counted.
    harness.clock.advance(by: 29 * Self.day)
    reader.clearReads()
    let before = await engine.reconcile(root)
    #expect(reader.readNames == ["bad.md"])
    #expect(before.failures.count == 1)
    #expect(await status(engine, root).failures.count == 1)

    // Past 30 days it is dropped everywhere and left alone.
    harness.clock.advance(by: 2 * Self.day)
    reader.clearReads()
    let report = await engine.reconcile(root)

    #expect(report.completed)
    #expect(report.failures.isEmpty)
    #expect(reader.readNames.isEmpty)
    #expect(await status(engine, root).failures.isEmpty)
    let doc = try await statusDoc(engine)
    #expect(doc.contains("- Failing files: none"))
    #expect(!doc.contains("bad.md"))
    #expect(try await harness.tree(engine) == ["Notes/", "Notes/_sync-status", "Notes/ok"])
  }

  @Test func skippingAnExpiredFileNeverTrashesItsDoc() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["a.md": "one"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    // The edit can't be read, so the Doc keeps the old text.
    try harness.write(root, "a.md", "one, edited")
    reader.setFailing(["a.md"])
    _ = await engine.reconcile(root)

    harness.clock.advance(by: 31 * Self.day)
    let report = await engine.reconcile(root)

    #expect(report.heldDeletions == 0)
    #expect(try await harness.docs(engine)["Notes/a"] == "one")
    #expect(await status(engine, root).mirroredFiles == 1)
  }

  @Test func aChangedFileIsRetriedAndStartsANewClock() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    harness.clock.advance(by: 31 * Self.day)
    _ = await engine.reconcile(root)
    #expect(await status(engine, root).failures.isEmpty)

    try harness.write(root, "bad.md", "x, edited")
    reader.clearReads()
    let report = await engine.reconcile(root)

    // Retried, failed again, and shown again as a new problem.
    #expect(reader.readNames == ["bad.md"])
    #expect(report.failures.count == 1)
    let failure = try #require(await status(engine, root).failures[try RelativePath("bad.md")])
    #expect(failure.firstSeen == harness.clock.now)
    #expect(try await statusDoc(engine).contains("(since Feb 15, 2027)"))
  }

  @Test func aChangedFileThatNowWorksIsUploaded() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    harness.clock.advance(by: 31 * Self.day)
    _ = await engine.reconcile(root)

    reader.setFailing([])
    try harness.write(root, "bad.md", "fixed")
    let report = await engine.reconcile(root)

    #expect(report.failures.isEmpty)
    #expect(try await harness.docs(engine)["Notes/bad"] == "fixed")
  }

  @Test func syncNowRetriesExpiredFailures() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    harness.clock.advance(by: 31 * Self.day)
    reader.setFailing([])

    // A background pass still leaves it alone, even though it would work now...
    reader.clearReads()
    _ = await engine.reconcile(root)
    #expect(reader.readNames.isEmpty)
    #expect(try await harness.docs(engine)["Notes/bad"] == nil)

    // ...and Sync Now tries it.
    let report = await engine.reconcile(root, retryExpiredFailures: true)
    #expect(report.failures.isEmpty)
    #expect(try await harness.docs(engine)["Notes/bad"] == "x")
    #expect(await status(engine, root).failures.isEmpty)
    #expect(try await statusDoc(engine).contains("- Failing files: none"))
  }

  @Test func syncNowThatFailsAgainResurfacesTheError() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    harness.clock.advance(by: 31 * Self.day)

    reader.clearReads()
    let report = await engine.reconcile(root, retryExpiredFailures: true)

    #expect(reader.readNames == ["bad.md"])
    #expect(report.failures.keys.map(\.value) == ["bad.md"])
    #expect(await status(engine, root).failures.count == 1)

    // It's a fresh problem now, so it stays visible for another 30 days of background passes.
    harness.clock.advance(by: 29 * Self.day)
    _ = await engine.reconcile(root)
    #expect(await status(engine, root).failures.count == 1)
  }

  @Test func aFailureThatIsFixedBeforeItExpiresIsCleared() async throws {
    defer { harness.cleanUp() }
    let root = try harness.makeRoot(files: ["bad.md": "x"])
    reader.setFailing(["bad.md"])
    let engine = harness.makeEngine(reader: reader)
    _ = await engine.reconcile(root)
    #expect(await status(engine, root).failures.count == 1)

    harness.clock.advance(by: 3 * Self.day)
    reader.setFailing([])
    let report = await engine.reconcile(root)

    #expect(report.failures.isEmpty)
    #expect(await status(engine, root).failures.isEmpty)
    #expect(try await harness.docs(engine)["Notes/bad"] == "x")
  }

  @Test func stateWithOldStringFailuresStillLoads() throws {
    let json = """
      {"version":1,"mirrorFolderID":"m","roots":{"11111111-2222-3333-4444-555555555555":
      {"folderID":"r","failures":{"a.md":"Couldn't read the file: nope"},
       "files":{"b.md":{"fileID":"f","contentHash":"h"}}}}}
      """
    let state = try JSONDecoder().decode(MirrorState.self, from: Data(json.utf8))
    let root = try #require(state.roots["11111111-2222-3333-4444-555555555555"])
    #expect(root.failures.isEmpty)
    #expect(root.files.count == 1)
    #expect(root.folderID == "r")
  }

  @Test func failuresRoundTripThroughTheStateFile() throws {
    var root = RootState()
    let date = Date(timeIntervalSince1970: 1_800_000_000.5)
    root.failures[try RelativePath("a.md")] = FailureRecord(
      message: "boom", firstSeen: date, lastSeen: date, size: 7, modified: date)
    var state = MirrorState()
    state[root: UUID()] = root
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(MirrorState.self, from: data) == state)
  }
}
