import Foundation
import Testing

@testable import MirrorCore

/// The coordinator tells the owner about a problem once, and again only after it has cleared.
@Suite struct ProblemNotificationTests {
  @Test func successNeverNotifies() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    try harness.saveConfig([try harness.engineHarness.makeRoot(files: ["a.md": "a"])])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.isEmpty)
    await coordinator.stop()
  }

  @Test func failingFilesNotifyOncePerRootAndAgainAfterClearing() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(
      files: ["a.md": "a", "b.md": "b", "c.md": "c", "ok.md": "ok"])
    try harness.saveConfig([root])
    harness.reader.setFailing(["a.md", "b.md", "c.md"])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    // Three failing files make one notification, and more syncs don't repeat it.
    #expect(await harness.notifier.titles == ["3 files failing in Notes"])
    await coordinator.syncNow()
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.count == 1)

    // A different count is still the same problem.
    harness.reader.setFailing(["a.md", "b.md"])
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.count == 1)

    // Fixed: nothing is announced, but the problem is forgotten...
    harness.reader.setFailing([])
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.count == 1)

    // ...so it is announced again when it comes back.
    try harness.engineHarness.write(root, "d.md", "d")
    harness.reader.setFailing(["d.md"])
    await coordinator.syncNow()
    #expect(
      await harness.notifier.titles == ["3 files failing in Notes", "1 file failing in Notes"])
    await coordinator.stop()
  }

  @Test func separateRootsNotifySeparately() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let notes = try harness.engineHarness.makeRoot(
      "Notes", files: ["bad1.md": "x", "bad2.md": "x"])
    let journal = try harness.engineHarness.makeRoot("Journal", files: ["bad3.md": "x"])
    try harness.saveConfig([notes, journal])
    harness.reader.setFailing(["bad1.md", "bad2.md", "bad3.md"])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    #expect(
      Set(await harness.notifier.titles)
        == ["2 files failing in Notes", "1 file failing in Journal"])
    await coordinator.stop()
  }

  @Test func heldDeletionsNotifyOnceUntilApplied() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let files = Dictionary(uniqueKeysWithValues: (0..<20).map { ("n\($0).md", "note \($0)") })
    let root = try harness.engineHarness.makeRoot(files: files)
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    #expect(await harness.notifier.sent.isEmpty)

    for i in 0..<12 { try harness.engineHarness.remove(root, "n\(i).md") }
    await coordinator.syncNow()
    await coordinator.syncNow()
    #expect(await harness.notifier.titles == ["12 deletions on hold in Notes"])

    await coordinator.applyPendingDeletions(root: root.id)
    #expect(await harness.notifier.sent.count == 1)
    await coordinator.stop()
  }

  @Test func expiredSignInNotifiesOnceAndOnlyThat() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    await harness.auth.expire()
    try harness.engineHarness.write(root, "a.md", "changed")
    await coordinator.syncNow()
    await coordinator.syncNow()

    // The file that failed because of the expiry isn't announced as its own problem.
    #expect(await harness.notifier.titles == ["Google sign-in expired"])

    await coordinator.signIn()
    #expect(await harness.notifier.sent.count == 1)
    await harness.auth.expire()
    try harness.engineHarness.write(root, "a.md", "changed again")
    await coordinator.syncNow()
    #expect(await harness.notifier.titles == ["Google sign-in expired", "Google sign-in expired"])
    await coordinator.stop()
  }

  @Test func unavailableFolderNotifiesOnceAndAgainAfterItReturns() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    let saved = root.url.deletingLastPathComponent().appending(path: "parked")
    try FileManager.default.moveItem(at: root.url, to: saved)
    await coordinator.syncNow()
    await coordinator.syncNow()
    #expect(await harness.notifier.titles == ["Can't reach the Notes folder"])

    try FileManager.default.moveItem(at: saved, to: root.url)
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.count == 1)

    try FileManager.default.moveItem(at: root.url, to: saved)
    await coordinator.syncNow()
    #expect(await harness.notifier.sent.count == 2)
    await coordinator.stop()
  }

  @Test func missingBookmarkFolderNotifiesAtLaunch() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    var root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    root.bookmark = try FolderBookmark.create(for: root.url)
    try harness.saveConfig([root])
    try FileManager.default.removeItem(at: root.url)

    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    #expect(await harness.notifier.titles == ["Can't reach the Notes folder"])
    await coordinator.stop()
  }
}
