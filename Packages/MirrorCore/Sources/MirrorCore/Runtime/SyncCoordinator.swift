import Foundation

/// Runs the app: decides when roots reconcile (launch, wake, file changes, the periodic full pass, Sync Now),
/// owns the configuration and sign-in, and publishes a `MirrorSnapshot` for the UI.
public actor SyncCoordinator<C: Clock<Duration>>: MirrorService {
  public struct Dependencies: Sendable {
    public var paths: AppPaths
    public var clock: C
    public var makeAuth: @Sendable (OAuthClientConfig) -> any AuthSession
    public var makeEngine: @Sendable (any AuthSession, UpdateStrategy) -> any ReconcileEngine
    /// Looks up the signed-in email; nil when Drive won't say.
    public var lookUpEmail: @Sendable (any AuthSession) async -> String?
    public var openBrowser: @Sendable (URL) async -> Void
    public var watcher: any FolderWatching
    public var log: MirrorLog
    public var notifier: any ProblemNotifying
    public var quietPeriod: Duration = .seconds(3)

    public init(
      paths: AppPaths, clock: C,
      makeAuth: @escaping @Sendable (OAuthClientConfig) -> any AuthSession,
      makeEngine: @escaping @Sendable (any AuthSession, UpdateStrategy) -> any ReconcileEngine,
      lookUpEmail: @escaping @Sendable (any AuthSession) async -> String?,
      openBrowser: @escaping @Sendable (URL) async -> Void,
      watcher: any FolderWatching, log: MirrorLog, notifier: any ProblemNotifying
    ) {
      self.paths = paths
      self.clock = clock
      self.makeAuth = makeAuth
      self.makeEngine = makeEngine
      self.lookUpEmail = lookUpEmail
      self.openBrowser = openBrowser
      self.watcher = watcher
      self.log = log
      self.notifier = notifier
    }
  }

  private let deps: Dependencies
  private let configStore: JSONFileStore<MirrorConfig>
  private var config = MirrorConfig()
  private var auth: (any AuthSession)?
  private var engine: (any ReconcileEngine)?
  private var snapshot = MirrorSnapshot()
  private var lastReports: [UUID: RootSyncReport] = [:]
  private var syncing: Set<UUID> = []
  /// Roots whose folder couldn't be found from their bookmark.
  private var missingFolders: [UUID: String] = [:]
  /// Set when Drive rejects our credentials; cleared by signing in again.
  private var signInExpired = false
  /// Problems the owner has already been told about. A problem is announced when it first
  /// appears and not again until it has cleared and come back.
  private var announcedProblems: Set<String> = []
  private var subscribers: [UUID: AsyncStream<MirrorSnapshot>.Continuation] = [:]
  private var debouncer: Debouncer<C>?
  private var fullPassTask: Task<Void, Never>?

  public init(_ deps: Dependencies) {
    self.deps = deps
    configStore = JSONFileStore(url: deps.paths.configFile)
  }

  // MARK: - Lifecycle

  /// Loads everything and runs the launch reconcile.
  public func start() async {
    switch configStore.load() {
    case .loaded(let loaded): config = loaded
    case .missing: config = MirrorConfig()
    case .corrupt(let reason):
      // Don't overwrite a config we can't read; the owner's root list is in there.
      let backup = configStore.url.appendingPathExtension("corrupt")
      try? FileManager.default.removeItem(at: backup)
      try? FileManager.default.copyItem(at: configStore.url, to: backup)
      snapshot.message = "Settings couldn't be read and were reset. A copy is at \(backup.path)."
      deps.log.error("config unreadable: \(reason)")
    }
    resolveBookmarks()
    await loadAuth()

    let debouncer = Debouncer(clock: deps.clock, quietPeriod: deps.quietPeriod) {
      [weak self] root, _ in
      // Every reconcile is a full one, so a full-rescan flag needs no special handling.
      Task { await self?.sync(root, explicit: false) }
    }
    self.debouncer = debouncer
    await restartWatcher()
    startFullPassTimer()
    deps.log.info("started with \(config.roots.count) roots")
    await syncAll(explicit: false)
  }

  public func stop() async {
    fullPassTask?.cancel()
    await debouncer?.cancelAll()
    await deps.watcher.stop()
    for subscriber in subscribers.values { subscriber.finish() }
    subscribers = [:]
  }

  /// The Mac woke up; files may have changed while it slept.
  public func handleWake() async {
    deps.log.info("woke from sleep")
    await syncAll(explicit: false)
  }

  // MARK: - MirrorService

  public func snapshots() -> AsyncStream<MirrorSnapshot> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: MirrorSnapshot.self, bufferingPolicy: .bufferingNewest(1))
    let id = UUID()
    subscribers[id] = continuation
    continuation.onTermination = { [weak self] _ in
      Task { await self?.unsubscribe(id) }
    }
    continuation.yield(snapshot)
    return stream
  }

  public func syncNow() async { await syncAll(explicit: true) }

  public func setPaused(_ paused: Bool) async {
    config.isPaused = paused
    saveConfig()
    await publish()
    deps.log.info(paused ? "paused" : "resumed")
    // Changes made while paused were ignored, so catch up right away.
    if !paused { await syncAll(explicit: false) }
  }

  public func applyPendingDeletions(root: UUID) async {
    deps.log.info("applying pending deletions for \(root)")
    await sync(root, explicit: true, applyPendingDeletions: true)
  }

  public func addRoot(at url: URL, displayName: String) async throws {
    let root = RootConfig(
      displayName: displayName, path: url.standardizedFileURL.path,
      bookmark: try FolderBookmark.create(for: url))
    config.roots.append(root)
    saveConfig()
    deps.log.info("added root \(displayName) at \(url.path)")
    await restartWatcher()
    await publish()
    await sync(root.id, explicit: true)
  }

  public func removeRoot(_ id: UUID, trashDriveFolder: Bool) async throws {
    if let engine {
      try await engine.removeRoot(id, trashDriveFolder: trashDriveFolder)
    } else if trashDriveFolder {
      throw AuthError.signedOut
    } else {
      // Signed out: forget the root's state directly.
      let store = JSONFileStore<MirrorState>(url: deps.paths.stateFile)
      if case .loaded(var state) = store.load() {
        state.roots[id.uuidString] = nil
        try store.save(state)
      }
    }
    config.roots.removeAll { $0.id == id }
    lastReports[id] = nil
    missingFolders[id] = nil
    saveConfig()
    deps.log.info("removed root \(id) (trashed Drive folder: \(trashDriveFolder))")
    await restartWatcher()
    await publish()
  }

  public func updateRoot(_ updated: RootConfig) async throws {
    guard let index = config.roots.firstIndex(where: { $0.id == updated.id }) else { return }
    config.roots[index] = updated
    saveConfig()
    await restartWatcher()
    await publish()
    await sync(updated.id, explicit: true)
  }

  public func setUpdateStrategy(_ strategy: UpdateStrategy) async {
    config.updateStrategy = strategy
    saveConfig()
    await engine?.setUpdateStrategy(strategy)
    await publish()
  }

  public func setDriveFolderName(_ name: String) async {
    config.driveFolderName = MirrorConfig.normalizedDriveFolderName(name)
    saveConfig()
    await engine?.setDriveFolderName(config.driveFolderName)
    await publish()
    // The rename happens during a reconcile; run one so the change shows up in Drive now.
    await syncAll(explicit: false)
  }

  public func setFullSyncInterval(_ interval: FullSyncInterval) async {
    guard interval != config.fullSyncInterval else { return }
    config.fullSyncInterval = interval
    saveConfig()
    // Restarting measures the new interval from now, which is what the owner just asked for.
    startFullPassTimer()
    await publish()
  }

  public func importClientFile(from url: URL) async throws {
    _ = try ClientFile.importFile(from: url, applicationSupport: deps.paths.applicationSupport)
    deps.log.info("imported OAuth client file")
    await loadAuth()
  }

  public func signIn() async {
    guard let auth else {
      snapshot.message = "Import your Google client file before signing in."
      await publish()
      return
    }
    do {
      try await auth.signIn(openBrowser: deps.openBrowser)
      snapshot.message = nil
      // Reports from before an expiry describe failures the new sign-in will probably fix.
      lastReports = [:]
      deps.log.info("signed in")
      await adoptSignedIn(auth)
      await syncAll(explicit: true)
    } catch {
      snapshot.message = "Sign-in failed: \(error)"
      deps.log.error("sign-in failed: \(error)")
      await publish()
    }
  }

  public func signOut() async {
    try? await auth?.signOut()
    engine = nil
    signInExpired = false
    snapshot.account = auth == nil ? .needsClientFile : .signedOut
    deps.log.info("signed out")
    await publish()
  }

  public func diagnostics() -> String {
    var lines = ["Drive Mirror diagnostics", "Account: \(snapshot.account)"]
    lines.append("Paused: \(config.isPaused), update strategy: \(config.updateStrategy.rawValue)")
    for root in snapshot.roots {
      lines.append(
        "Root \(root.config.displayName) [\(root.id)] at \(root.config.path): \(root.phase), "
          + "\(root.mirroredFiles) mirrored, \(root.failingFiles) failing, "
          + "\(root.heldDeletions) held deletions, last sync \(root.lastSuccessfulSync.map { "\($0)" } ?? "never")"
      )
    }
    lines.append("")
    lines.append("Recent log:")
    lines += deps.log.recentLines(200)
    return lines.joined(separator: "\n")
  }

  // MARK: - Syncing

  private func syncAll(explicit: Bool) async {
    let ids = config.roots.map(\.id)
    await withTaskGroup(of: Void.self) { group in
      for id in ids { group.addTask { await self.sync(id, explicit: explicit) } }
    }
  }

  private func sync(_ id: UUID, explicit: Bool, applyPendingDeletions: Bool = false) async {
    guard let root = config.roots.first(where: { $0.id == id }), let engine else { return }
    guard explicit || !config.isPaused else { return }
    guard missingFolders[id] == nil else { return }

    syncing.insert(id)
    await publish()
    let report = await engine.reconcile(root, applyPendingDeletions: applyPendingDeletions)
    syncing.remove(id)
    lastReports[id] = report
    log(report, root: root)

    // An expired sign-in surfaces as per-file failures, so check whenever anything failed.
    let hadFailures = report.error != nil || !report.failures.isEmpty
    if hadFailures, let auth, !(await auth.isSignedIn) {
      self.engine = nil
      signInExpired = true
      snapshot.account = .signedOut
      snapshot.message = "Google sign-in expired. Sign in again from Settings."
    }
    await refreshDriveDetails()
    await publish()
  }

  private func log(_ report: RootSyncReport, root: RootConfig) {
    var summary = "synced \(root.displayName): \(report.applied) changes"
    if !report.failures.isEmpty { summary += ", \(report.failures.count) failing" }
    if !report.deferred.isEmpty { summary += ", \(report.deferred.count) waiting for download" }
    if report.heldDeletions > 0 { summary += ", \(report.heldDeletions) deletions held" }
    if let error = report.error {
      deps.log.error("\(summary); error: \(error)")
    } else {
      deps.log.info(summary)
    }
    for (path, failure) in report.failures.sorted(by: { $0.key < $1.key }) {
      deps.log.error("  \(root.displayName)/\(path): \(failure)")
    }
  }

  private func startFullPassTimer() {
    fullPassTask?.cancel()
    let clock = deps.clock
    let interval = config.fullSyncInterval.duration
    fullPassTask = Task { [weak self] in
      while !Task.isCancelled {
        do { try await clock.sleep(for: interval) } catch { return }
        await self?.syncAll(explicit: false)
      }
    }
  }

  private func restartWatcher() async {
    let roots = config.roots.filter { missingFolders[$0.id] == nil }
      .map { WatchedRoot(id: $0.id, url: $0.url) }
    let debouncer = debouncer
    let paused: @Sendable () async -> Bool = { [weak self] in await self?.isPaused ?? true }
    await deps.watcher.start(roots: roots) { events in
      Task {
        guard !(await paused()) else { return }
        for event in events {
          await debouncer?.record(root: event.root, fullRescan: event.needsFullReconcile)
        }
      }
    }
  }

  private var isPaused: Bool { config.isPaused }

  // MARK: - Configuration and account

  /// Follows each root's bookmark, so a renamed or moved folder is found again.
  private func resolveBookmarks() {
    for index in config.roots.indices {
      guard let bookmark = config.roots[index].bookmark else { continue }
      let root = config.roots[index]
      do {
        let (url, isStale) = try FolderBookmark.resolve(bookmark)
        let path = url.standardizedFileURL.path
        if path != root.path {
          deps.log.info("root \(root.displayName) moved to \(path)")
          config.roots[index].path = path
        }
        if isStale || path != root.path {
          config.roots[index].bookmark = try? FolderBookmark.create(for: url)
          saveConfig()
        }
        missingFolders[root.id] = nil
      } catch {
        missingFolders[root.id] =
          "Can't find the folder \(root.path): \(error.localizedDescription)"
        deps.log.error("bookmark for \(root.displayName) failed: \(error)")
      }
    }
  }

  private func loadAuth() async {
    guard let clientConfig = try? ClientFile.load(applicationSupport: deps.paths.applicationSupport)
    else {
      auth = nil
      engine = nil
      snapshot.account = .needsClientFile
      await publish()
      return
    }
    let auth = deps.makeAuth(clientConfig)
    self.auth = auth
    if await auth.isSignedIn {
      await adoptSignedIn(auth)
    } else {
      engine = nil
      snapshot.account = .signedOut
      await publish()
    }
  }

  private func adoptSignedIn(_ auth: any AuthSession) async {
    let engine = deps.makeEngine(auth, config.updateStrategy)
    // Set before publishing the engine, so no reconcile can start with the default name.
    await engine.setDriveFolderName(config.driveFolderName)
    self.engine = engine
    signInExpired = false
    snapshot.account = .signedIn(email: await deps.lookUpEmail(auth))
    await refreshDriveDetails()
    await publish()
  }

  private func refreshDriveDetails() async {
    snapshot.mirrorFolderID = await engine?.mirrorFolderID()
  }

  private func saveConfig() {
    do {
      try configStore.save(config)
    } catch {
      deps.log.error("couldn't save settings: \(error)")
      snapshot.message = "Settings couldn't be saved: \(error.localizedDescription)"
    }
  }

  // MARK: - Snapshots

  private func publish() async {
    snapshot.isPaused = config.isPaused
    snapshot.updateStrategy = config.updateStrategy
    snapshot.driveFolderName = config.driveFolderName
    snapshot.fullSyncInterval = config.fullSyncInterval
    var roots: [RootSnapshot] = []
    for root in config.roots {
      var status = RootSnapshot(config: root)
      let report = lastReports[root.id]
      let stored = await engine?.status(of: root.id)
      status.mirroredFiles = stored?.mirroredFiles ?? 0
      status.lastSuccessfulSync = stored?.lastSuccessfulSync
      status.failingFiles = report?.failures.count ?? stored?.failures.count ?? 0
      status.heldDeletions = report?.heldDeletions ?? 0
      status.phase = phase(for: root.id, report: report)
      roots.append(status)
    }
    snapshot.roots = roots
    let current = snapshot
    for subscriber in subscribers.values { subscriber.yield(current) }
    await announceNewProblems()
  }

  // MARK: - Problem notifications

  private struct Problem {
    var id: String
    var title: String
    var body: String
  }

  private func currentProblems() -> [Problem] {
    // Everything else follows from an expired sign-in (every upload fails), so say only that.
    if signInExpired {
      return [
        Problem(
          id: "sign-in", title: "Google sign-in expired",
          body: "Sign in again from \(AppIdentity.displayName) Settings to resume syncing.")
      ]
    }
    var problems: [Problem] = []
    for root in config.roots {
      let name = root.displayName
      if let reason = unavailableReason(for: root.id) {
        problems.append(
          Problem(
            id: "unavailable:\(root.id)", title: "Can't reach the \(name) folder", body: reason)
        )
      }
      guard let report = lastReports[root.id] else { continue }
      if !report.failures.isEmpty {
        let count = report.failures.count
        problems.append(
          Problem(
            id: "failing:\(root.id)",
            title: "\(count) \(count == 1 ? "file" : "files") failing in \(name)",
            body:
              "They'll be retried automatically. Choose Copy Diagnostics in the menu to see why."
          ))
      }
      if report.heldDeletions > 0 {
        problems.append(
          Problem(
            id: "held:\(root.id)", title: "\(report.heldDeletions) deletions on hold in \(name)",
            body: "That looks like a mistake, so nothing was trashed. Choose Apply Pending "
              + "Deletions in the menu if they're right."))
      }
    }
    return problems
  }

  private func unavailableReason(for id: UUID) -> String? {
    if let missing = missingFolders[id] { return missing }
    if case .rootUnavailable(let reason)? = lastReports[id]?.attention { return reason }
    return nil
  }

  private func announceNewProblems() async {
    let problems = currentProblems()
    let fresh = problems.filter { !announcedProblems.contains($0.id) }
    // Record before awaiting: this actor can run another publish while a notification is
    // being delivered, and that one must not announce the same problem again.
    announcedProblems = Set(problems.map(\.id))
    for problem in fresh {
      await deps.notifier.notify(title: problem.title, body: problem.body, id: problem.id)
    }
  }

  private func phase(for id: UUID, report: RootSyncReport?) -> RootPhase {
    if let missing = missingFolders[id] { return .error(missing) }
    if syncing.contains(id) { return .syncing }
    guard let report else { return .idle }
    if let error = report.error { return .error(error) }
    switch report.attention {
    case .rootUnavailable(let reason): return .error(reason)
    case .massDeletion(let pending, let mirrored):
      return .needsAttention(
        "\(pending) of \(mirrored) Docs would be trashed. Deletions are on hold.")
    case nil: break
    }
    if !report.failures.isEmpty {
      return .error("\(report.failures.count) file\(report.failures.count == 1 ? "" : "s") failing")
    }
    return .idle
  }

  private func unsubscribe(_ id: UUID) { subscribers[id] = nil }
}
