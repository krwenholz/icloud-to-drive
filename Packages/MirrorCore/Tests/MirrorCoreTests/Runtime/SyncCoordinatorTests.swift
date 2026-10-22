import Foundation
import Testing
import os

@testable import MirrorCore

/// A sign-in that tests flip by hand.
actor FakeAuth: AuthSession {
  var signedIn: Bool
  init(signedIn: Bool) { self.signedIn = signedIn }

  var isSignedIn: Bool { signedIn }
  func signIn(openBrowser: @Sendable (URL) async -> Void) async throws {
    await openBrowser(URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!)
    signedIn = true
  }
  func signOut() { signedIn = false }
  func expire() { signedIn = false }
  func accessToken() throws -> String {
    guard signedIn else { throw AuthError.signedOut }
    return "token"
  }
  func invalidateAccessToken() {}
}

/// A drive that checks the token first, like the real client.
struct AuthCheckingDrive: DriveClient {
  let base: InMemoryDriveClient
  let auth: FakeAuth

  private func check() async throws { _ = try await auth.accessToken() }

  func createFolder(
    name: String, parentID: String?, description: String?, appProperties: [String: String]
  ) async throws -> DriveFile {
    try await check()
    return try await base.createFolder(
      name: name, parentID: parentID, description: description, appProperties: appProperties)
  }
  func createFile(
    markdown: Data, name: String, parentID: String, description: String,
    appProperties: [String: String], convert: Bool
  ) async throws -> DriveFile {
    try await check()
    return try await base.createFile(
      markdown: markdown, name: name, parentID: parentID, description: description,
      appProperties: appProperties, convert: convert)
  }
  func updateFile(id: String, markdown: Data, description: String, appProperties: [String: String])
    async throws -> DriveFile
  {
    try await check()
    return try await base.updateFile(
      id: id, markdown: markdown, description: description, appProperties: appProperties)
  }
  func moveFile(
    id: String, name: String?, description: String?, appProperties: [String: String]?,
    addParent: String?, removeParent: String?
  ) async throws -> DriveFile {
    try await check()
    return try await base.moveFile(
      id: id, name: name, description: description, appProperties: appProperties,
      addParent: addParent, removeParent: removeParent)
  }
  func getFile(id: String) async throws -> DriveFile {
    try await check()
    return try await base.getFile(id: id)
  }
  func trashFile(id: String) async throws {
    try await check()
    try await base.trashFile(id: id)
  }
  func listFiles(appProperty key: String, value: String) async throws -> [DriveFile] {
    try await check()
    return try await base.listFiles(appProperty: key, value: value)
  }
  func userEmail() async throws -> String? { try await base.userEmail() }
}

actor FakeWatcher: FolderWatching {
  private(set) var roots: [WatchedRoot] = []
  private var handler: (@Sendable ([FolderEvent]) -> Void)?

  func start(roots: [WatchedRoot], handler: @escaping @Sendable ([FolderEvent]) -> Void) {
    self.roots = roots
    self.handler = handler
  }
  func stop() { handler = nil }
  func emit(_ events: [FolderEvent]) { handler?(events) }
}

struct CoordinatorHarness {
  let engineHarness: EngineHarness
  let clock = ManualClock()
  let auth: FakeAuth
  let watcher = FakeWatcher()
  let notifier = RecordingNotifier()
  let engineCalls = EngineCallLog()
  let reader = ScriptedReader()
  let opened = OpenedURLs()
  var paths: AppPaths { engineHarness.paths }
  var drive: InMemoryDriveClient { engineHarness.drive }

  init(signedIn: Bool = true, clientFile: Bool = true) throws {
    engineHarness = try EngineHarness()
    auth = FakeAuth(signedIn: signedIn)
    if clientFile { try writeClientFile() }
  }

  func writeClientFile() throws {
    try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
    try Data(
      #"{"installed":{"client_id":"id","client_secret":"secret","auth_uri":"https://accounts.google.com/o/oauth2/auth","token_uri":"https://oauth2.googleapis.com/token"}}"#
        .utf8
    ).write(to: paths.clientFile)
  }

  func makeCoordinator() -> SyncCoordinator<ManualClock> {
    let auth = auth
    let drive = drive
    let harness = engineHarness
    let opened = opened
    let reader = reader
    let engineCalls = engineCalls
    return SyncCoordinator(
      .init(
        paths: paths, clock: clock,
        makeAuth: { _ in auth },
        makeEngine: { _, strategy in
          LoggingEngine(
            base: harness.makeEngine(
              strategy: strategy, reader: reader,
              drive: AuthCheckingDrive(base: drive, auth: auth)),
            log: engineCalls)
        },
        lookUpEmail: { _ in "me@example.com" },
        openBrowser: { await opened.append($0) },
        watcher: watcher,
        log: MirrorLog(file: RollingLogFile(url: paths.logFile)), notifier: notifier))
  }

  func saveConfig(_ roots: [RootConfig]) throws {
    try JSONFileStore<MirrorConfig>(url: paths.configFile).save(MirrorConfig(roots: roots))
  }

  func savedConfig() -> MirrorConfig? {
    if case .loaded(let config) = JSONFileStore<MirrorConfig>(url: paths.configFile).load() {
      return config
    }
    return nil
  }

  func docNames() async -> Set<String> {
    Set(
      await drive.items.values.filter { !$0.trashed && !$0.file.isFolder }.map(\.file.name))
  }
}

/// Remembers how the coordinator called `reconcile`.
final class EngineCallLog: Sendable {
  private let flags = OSAllocatedUnfairLock(initialState: [Bool]())
  var retryExpiredFlags: [Bool] { flags.withLock { $0 } }
  func record(retryExpired: Bool) { flags.withLock { $0.append(retryExpired) } }
}

/// A real engine that logs the flags it is called with.
struct LoggingEngine: ReconcileEngine {
  let base: SyncEngine
  let log: EngineCallLog

  func reconcile(_ root: RootConfig, applyPendingDeletions: Bool, retryExpiredFailures: Bool)
    async -> RootSyncReport
  {
    log.record(retryExpired: retryExpiredFailures)
    return await base.reconcile(
      root, applyPendingDeletions: applyPendingDeletions,
      retryExpiredFailures: retryExpiredFailures)
  }
  func removeRoot(_ rootID: UUID, trashDriveFolder: Bool) async throws {
    try await base.removeRoot(rootID, trashDriveFolder: trashDriveFolder)
  }
  func status(of rootID: UUID) async -> RootStatus { await base.status(of: rootID) }
  func mirrorFolderID() async -> String? { await base.mirrorFolderID() }
  func setUpdateStrategy(_ strategy: UpdateStrategy) async {
    await base.setUpdateStrategy(strategy)
  }
  func setDriveFolderName(_ name: String) async { await base.setDriveFolderName(name) }
}

/// Records every notification the coordinator asks for.
actor RecordingNotifier: ProblemNotifying {
  struct Notification: Equatable {
    var title: String
    var id: String
  }
  private(set) var sent: [Notification] = []
  var titles: [String] { sent.map(\.title) }
  func notify(title: String, body: String, id: String) {
    sent.append(Notification(title: title, id: id))
  }
}

actor OpenedURLs {
  private(set) var urls: [URL] = []
  func append(_ url: URL) { urls.append(url) }
}

/// Reads snapshots as they're published.
final class SnapshotRecorder: @unchecked Sendable {
  // @unchecked: `latest` is guarded by `lock`.
  private let lock = NSLock()
  private var latestSnapshot = MirrorSnapshot()
  private var task: Task<Void, Never>?

  init(_ coordinator: SyncCoordinator<ManualClock>) async {
    let stream = await coordinator.snapshots()
    task = Task { [lock] in
      for await snapshot in stream { lock.withLock { self.latestSnapshot = snapshot } }
    }
  }

  var latest: MirrorSnapshot { lock.withLock { latestSnapshot } }
}

@Suite struct SyncCoordinatorTests {
  @Test func launchReconcilesConfiguredRoots() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a", "sub/b.md": "b"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)

    await coordinator.start()

    #expect(await harness.docNames() == ["a", "b", StatusDoc.name])
    #expect(await eventually { recorder.latest.roots.first?.mirroredFiles == 2 })
    let snapshot = recorder.latest
    #expect(snapshot.account == .signedIn(email: "me@example.com"))
    #expect(snapshot.roots.first?.phase == .idle)
    #expect(snapshot.mirrorFolderID != nil)
    #expect(await harness.watcher.roots.map(\.id) == [root.id])
    await coordinator.stop()
  }

  @Test func withoutClientFileNothingSyncs() async throws {
    let harness = try CoordinatorHarness(clientFile: false)
    defer { harness.engineHarness.cleanUp() }
    try harness.saveConfig([try harness.engineHarness.makeRoot(files: ["a.md": "a"])])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)

    await coordinator.start()

    #expect(await eventually { recorder.latest.account == .needsClientFile })
    #expect(await harness.drive.calls.isEmpty)
    await coordinator.stop()
  }

  @Test func signInFindsAClientFileAddedAfterLaunchAndClearsTheOldMessage() async throws {
    let harness = try CoordinatorHarness(signedIn: false, clientFile: false)
    defer { harness.engineHarness.cleanUp() }
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    #expect(recorder.latest.account == .loading)
    await coordinator.start()

    await coordinator.signIn()
    #expect(
      await eventually {
        recorder.latest.message == SyncCoordinator<ManualClock>.needsClientFileMessage
      })

    try harness.writeClientFile()
    await coordinator.signIn()

    #expect(await eventually { recorder.latest.account == .signedIn(email: "me@example.com") })
    #expect(recorder.latest.message == nil)
    await coordinator.stop()
  }

  @Test func signingInStartsSyncing() async throws {
    let harness = try CoordinatorHarness(signedIn: false)
    defer { harness.engineHarness.cleanUp() }
    try harness.saveConfig([try harness.engineHarness.makeRoot(files: ["a.md": "a"])])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    #expect(await harness.drive.calls.isEmpty)

    await coordinator.signIn()

    #expect(await harness.opened.urls.count == 1)
    #expect(await harness.docNames() == ["a", StatusDoc.name])
    await coordinator.stop()
  }

  @Test func fileEventsSyncAfterQuietPeriod() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    try harness.engineHarness.write(root, "new.md", "new")
    await harness.watcher.emit([
      FolderEvent(root: root.id, path: try RelativePath("new.md"), needsFullReconcile: false)
    ])
    await harness.clock.waitForSleepers([.seconds(3), .seconds(3600)])
    #expect(await harness.docNames() == ["a", StatusDoc.name])

    harness.clock.advance(by: .seconds(3))
    #expect(await eventually { await harness.docNames().contains("new") })
    await coordinator.stop()
  }

  @Test func pauseIgnoresEventsAndResumeCatchesUp() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    await coordinator.setPaused(true)
    #expect(harness.savedConfig()?.isPaused == true)

    try harness.engineHarness.write(root, "new.md", "new")
    await harness.watcher.emit([FolderEvent(root: root.id, path: nil, needsFullReconcile: true)])
    harness.clock.advance(by: .seconds(5))
    #expect(!(await harness.docNames().contains("new")))

    await coordinator.setPaused(false)
    #expect(await harness.docNames().contains("new"))
    await coordinator.stop()
  }

  @Test func hourlyTimerReconciles() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    try harness.engineHarness.write(root, "later.md", "later")

    await harness.clock.waitForSleepers([.seconds(3600)])
    harness.clock.advance(by: .seconds(3600))

    #expect(await eventually { await harness.docNames().contains("later") })
    await coordinator.stop()
  }

  @Test func changingTheFullSyncIntervalRestartsTheTimer() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    await coordinator.start()
    await harness.clock.waitForSleepers([.seconds(3600)])

    await coordinator.setFullSyncInterval(.fifteenMinutes)
    #expect(harness.savedConfig()?.fullSyncInterval == .fifteenMinutes)
    #expect(await eventually { recorder.latest.fullSyncInterval == .fifteenMinutes })
    await harness.clock.waitForSleepers([.seconds(900)])

    // The old hour-long sleep is gone: a quarter of an hour is enough now.
    try harness.engineHarness.write(root, "later.md", "later")
    harness.clock.advance(by: .seconds(900))
    #expect(await eventually { await harness.docNames().contains("later") })

    await coordinator.setFullSyncInterval(.sixHours)
    await harness.clock.waitForSleepers([.seconds(900 + 6 * 3600)])
    try harness.engineHarness.write(root, "much-later.md", "much later")
    harness.clock.advance(by: .seconds(3600))
    #expect(!(await harness.docNames().contains("much-later")))
    harness.clock.advance(by: .seconds(5 * 3600))
    #expect(await eventually { await harness.docNames().contains("much-later") })
    await coordinator.stop()
  }

  @Test func onlySyncNowRetriesFailuresThatHaveAgedOut() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["bad.md": "x", "ok.md": "ok"])
    try harness.saveConfig([root])
    harness.reader.setFailing(["bad.md"])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    await coordinator.start()
    #expect(await eventually { recorder.latest.roots.first?.failingFiles == 1 })

    // A month later a background pass skips the file and the menu stops counting it.
    harness.engineHarness.clock.advance(by: 31 * 24 * 60 * 60)
    harness.reader.clearReads()
    await coordinator.handleWake()
    #expect(harness.reader.readNames.isEmpty)
    #expect(await eventually { recorder.latest.roots.first?.failingFiles == 0 })
    #expect(recorder.latest.roots.first?.phase == .idle)

    // Sync Now tries it again; it still fails, but quietly.
    await coordinator.syncNow()
    #expect(harness.reader.readNames == ["bad.md"])
    #expect(harness.engineCalls.retryExpiredFlags.suffix(2) == [false, true])
    #expect(await eventually { recorder.latest.roots.first?.phase == .idle })
    #expect(recorder.latest.roots.first?.failingFiles == 0)
    await coordinator.stop()
  }

  @Test func addAndRemoveRoots() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let coordinator = harness.makeCoordinator()
    await coordinator.start()
    let folder = try harness.engineHarness.makeRoot("Journal", files: ["day.md": "today"])

    try await coordinator.addRoot(at: folder.url, displayName: "Journal")

    let added = try #require(harness.savedConfig()?.roots.first)
    #expect(added.displayName == "Journal")
    #expect(added.bookmark != nil)
    #expect(await harness.docNames() == ["day", StatusDoc.name])
    #expect(await harness.watcher.roots.count == 1)

    try await coordinator.removeRoot(added.id, trashDriveFolder: true)
    #expect(harness.savedConfig()?.roots.isEmpty == true)
    #expect(await harness.watcher.roots.isEmpty)
    let mirror = try #require(
      await harness.drive.listFiles(appProperty: "t", value: "mirror").first)
    #expect(await harness.drive.treeListing(under: mirror.id).isEmpty)
    await coordinator.stop()
  }

  @Test func expiredSignInStopsSyncingAndSaysSo() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    await coordinator.start()

    await harness.auth.expire()
    try harness.engineHarness.write(root, "a.md", "changed")
    await coordinator.syncNow()

    #expect(await eventually { recorder.latest.account == .signedOut })
    #expect(recorder.latest.message?.contains("Sign in again") == true)
    await coordinator.stop()
  }

  @Test func followsBookmarkWhenFolderIsRenamed() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    var root = try harness.engineHarness.makeRoot(files: ["a.md": "a"])
    root.bookmark = try FolderBookmark.create(for: root.url)
    try harness.saveConfig([root])
    let renamed = root.url.deletingLastPathComponent().appending(path: "Renamed")
    try FileManager.default.moveItem(at: root.url, to: renamed)

    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    let saved = try #require(harness.savedConfig()?.roots.first)
    #expect(
      URL(filePath: saved.path).resolvingSymlinksInPath() == renamed.resolvingSymlinksInPath())
    #expect(await harness.docNames() == ["a", StatusDoc.name])
    await coordinator.stop()
  }

  @Test func driveFolderNameIsSavedAndRenamesTheFolder() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    try harness.saveConfig([try harness.engineHarness.makeRoot(files: ["a.md": "a"])])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    await coordinator.start()
    #expect(await eventually { recorder.latest.mirrorFolderID != nil })
    let mirrorID = try #require(recorder.latest.mirrorFolderID)

    await coordinator.setDriveFolderName("  Claude Notes ")
    #expect(harness.savedConfig()?.driveFolderName == "Claude Notes")
    #expect(await harness.drive.item(mirrorID)?.file.name == "Claude Notes")
    #expect(await eventually { recorder.latest.driveFolderName == "Claude Notes" })

    await coordinator.setDriveFolderName("")
    #expect(harness.savedConfig()?.driveFolderName == "iCloud Mirror")
    #expect(await harness.drive.item(mirrorID)?.file.name == "iCloud Mirror")
    await coordinator.stop()
  }

  @Test func snapshotsCarryTheHeldDeletionPaths() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    let files = Dictionary(
      uniqueKeysWithValues: (0..<40).map { ("n\(String(format: "%02d", $0)).md", "note \($0)") })
    let root = try harness.engineHarness.makeRoot(files: files)
    try harness.saveConfig([root])
    let coordinator = harness.makeCoordinator()
    let recorder = await SnapshotRecorder(coordinator)
    await coordinator.start()

    for i in 0..<25 { try harness.engineHarness.remove(root, "n\(String(format: "%02d", i)).md") }
    await coordinator.syncNow()

    #expect(await eventually { recorder.latest.roots.first?.heldDeletions == 25 })
    let held = try #require(recorder.latest.roots.first)
    #expect(held.heldDeletions == 25)
    #expect(held.heldDeletionPaths.count == 20)
    #expect(held.heldDeletionPaths.first == "n00.md")
    await coordinator.stop()
  }

  @Test func diagnosticsIncludeRootsAndLog() async throws {
    let harness = try CoordinatorHarness()
    defer { harness.engineHarness.cleanUp() }
    try harness.saveConfig([try harness.engineHarness.makeRoot(files: ["a.md": "a"])])
    let coordinator = harness.makeCoordinator()
    await coordinator.start()

    let text = await coordinator.diagnostics()
    #expect(text.contains("Root Notes"))
    #expect(text.contains("synced Notes: 1 changes"))
    await coordinator.stop()
  }
}
