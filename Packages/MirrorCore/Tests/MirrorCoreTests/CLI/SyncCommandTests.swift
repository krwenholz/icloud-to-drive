import Foundation
import Testing

@testable import MirrorCore

struct SyncCommandTests {
  @Test func dryRunListsCreatesFoldersAndCountsWithoutTouchingDrive() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder(files: [
      "a.md": "# A", "projects/garden.md": "# Garden",
    ])

    let code = await harness.runner().run(["sync", folder.path, "--dry-run"])

    #expect(code == 0)
    let text = harness.out.text
    #expect(text.contains("temporary root"))
    #expect(text.contains("create  a.md"))
    #expect(text.contains("create  projects/garden.md"))
    #expect(text.contains("folder  projects/"))
    #expect(text.contains("Summary: 2 create, 0 update, 0 move, 0 trash, 1 folders, 0 unchanged"))
    #expect(await harness.drive.calls.isEmpty)
  }

  @Test func dryRunAfterASyncShowsUpdateMoveAndTrash() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder(files: [
      "a.md": "# A", "old.md": "# Old", "gone.md": "# Gone", "same.md": "# Same",
    ])
    #expect(await harness.runner().run(["sync", folder.path]) == 0)
    #expect(harness.out.text.contains("Synced 'notes'"))

    try harness.write(folder, "a.md", "# A changed")
    try FileManager.default.moveItem(
      at: folder.appending(path: "old.md"), to: folder.appending(path: "new.md"))
    try FileManager.default.removeItem(at: folder.appending(path: "gone.md"))
    let callsBefore = await harness.drive.calls.count

    let dry = try CLIHarness.sharing(harness)
    #expect(await dry.runner().run(["sync", folder.path, "--dry-run"]) == 0)

    let text = dry.out.text
    #expect(text.contains("update  a.md"))
    #expect(text.contains("move    old.md -> new.md"))
    #expect(text.contains("trash   gone.md"))
    #expect(text.contains("Summary: 0 create, 1 update, 1 move, 1 trash, 0 folders, 1 unchanged"))
    #expect(await harness.drive.calls.count == callsBefore)
  }

  @Test func dryRunReportsAnUnavailableRootAsAnError() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let code = await harness.runner().run([
      "sync", harness.base.appending(path: "nope").path, "--dry-run",
    ])
    #expect(code == 1)
    #expect(harness.err.text.contains("not a folder"))
  }

  @Test func massDeletionGuardIsReported() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    var files: [String: String] = [:]
    for index in 0..<12 { files["n\(index).md"] = "# \(index)" }
    let folder = try harness.makeFolder(files: files)
    #expect(await harness.runner().run(["sync", folder.path]) == 0)
    for index in 0..<12 {
      try FileManager.default.removeItem(at: folder.appending(path: "n\(index).md"))
    }
    try harness.write(folder, "keep.md", "# keep")

    let dry = try CLIHarness.sharing(harness)
    #expect(await dry.runner().run(["sync", folder.path, "--dry-run"]) == 0)
    #expect(dry.out.text.contains("Mass deletion held: 12 of 12"))
    #expect(dry.out.text.contains("held    n0.md"))
  }

  @Test func syncUsesTheAppRootAndStateWhenTheFolderIsConfigured() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder(files: ["a.md": "# A"])
    let app = RootConfig(displayName: "Work", path: folder.path)
    try JSONFileStore<MirrorConfig>(url: harness.paths.configFile)
      .save(MirrorConfig(roots: [app], updateStrategy: .replace))

    #expect(await harness.runner().run(["sync", folder.path]) == 0)

    #expect(harness.out.text.contains("from the app's config"))
    let state = try #require(
      { () -> MirrorState? in
        if case .loaded(let state) = JSONFileStore<MirrorState>(url: harness.paths.stateFile).load()
        {
          return state
        }
        return nil
      }())
    #expect(state[root: app.id].files.count == 1)
  }

  @Test func rebuildStateRecoversFilesFromDrive() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let folder = try harness.makeFolder(files: ["a.md": "# A", "b.md": "# B"])
    #expect(await harness.runner().run(["sync", folder.path]) == 0)
    let resolved = RootResolver.resolve(
      path: folder.path, config: MirrorConfig(), paths: harness.paths)
    try JSONFileStore<MirrorState>(url: resolved.stateFile).remove()

    let again = try CLIHarness.sharing(harness)
    #expect(await again.runner().run(["rebuild-state", folder.path]) == 0)
    #expect(again.out.text.contains("2 files found"))
  }

  @Test func authPrintsTheEmailOrJustSignedIn() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    #expect(await harness.runner().run(["auth"]) == 0)
    #expect(await harness.runner(email: nil).run(["auth"]) == 0)
    #expect(harness.out.text.contains("Signed in as me@example.com"))
    #expect(harness.out.text.hasSuffix("Signed in"))
  }

  @Test func missingClientFileExplainsWhereToPutIt() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let paths = harness.paths
    let err = harness.err
    let runner = CLIRunner(
      environment: CLIEnvironment(
        paths: paths, out: { _ in }, err: { err.append($0) },
        makeDrive: { throw AuthError.clientFileMissing(paths.clientFile) },
        signIn: { throw AuthError.clientFileMissing(paths.clientFile) }))
    #expect(await runner.run(["auth"]) == 1)
    #expect(err.text.contains("google-client.json"))
    #expect(err.text.contains(paths.clientFile.path))
  }
}

extension CLIHarness {
  /// A fresh output log over the same temp directory and Drive, so a second command's output
  /// can be read on its own.
  static func sharing(_ other: CLIHarness) throws -> CLIHarness {
    try CLIHarness(base: other.base, drive: other.drive)
  }
}
