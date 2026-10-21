import Foundation

/// Runs one `mirrorctl` command and returns its exit code: 0 on success, 1 when something
/// failed, 2 for misuse.
public struct CLIRunner: Sendable {
  public let environment: CLIEnvironment

  public init(environment: CLIEnvironment) { self.environment = environment }

  public func run(_ arguments: [String]) async -> Int32 {
    let command: CLICommand
    do {
      command = try CLIParser.parse(arguments)
    } catch {
      if error != .noCommand { environment.err("mirrorctl: \(error)") }
      environment.err(CLIParser.usage)
      return 2
    }
    do {
      switch command {
      case .help:
        environment.out(CLIParser.usage)
        return 0
      case .auth: return try await auth()
      case .probe: return try await probe()
      case .sync(let path, let dryRun):
        return dryRun ? try await dryRunSync(path) : try await sync(path)
      case .rebuildState(let path): return try await rebuildState(path)
      }
    } catch {
      environment.err("mirrorctl: \(Self.describe(error, paths: environment.paths))")
      return 1
    }
  }

  static func describe(_ error: any Error, paths: AppPaths) -> String {
    if case AuthError.clientFileMissing = error {
      return "No Google client file. Put google-client.json (a Desktop app OAuth client) at "
        + paths.clientFile.path
    }
    let text = (error as? LocalizedError)?.errorDescription ?? "\(error)"
    if case AuthError.signedOut = error { return text + " Run 'mirrorctl auth'." }
    return text
  }

  // MARK: - Commands

  private func auth() async throws -> Int32 {
    let email = try await environment.signIn()
    environment.out(email.map { "Signed in as \($0)" } ?? "Signed in")
    return 0
  }

  private func probe() async throws -> Int32 {
    let drive = try await environment.makeDrive()
    let report = await DriveProbe(drive: drive, now: environment.now).run()
    for line in report.render() { environment.out(line) }
    return report.passed ? 0 : 1
  }

  private func dryRunSync(_ path: String) async throws -> Int32 {
    let resolved = try resolve(path)
    guard try requireFolder(resolved) else { return 1 }
    let state: MirrorState
    switch JSONFileStore<MirrorState>(url: resolved.stateFile).load() {
    case .loaded(let loaded): state = loaded
    case .missing: state = MirrorState()
    case .corrupt(let message): throw CLIError.message(message)
    }
    let rootState = state[root: resolved.root.id]
    if rootState.files.isEmpty {
      environment.out(
        "No saved state for this folder, so every file shows as create. A real sync first "
          + "looks in Drive for existing copies.")
    }

    let outcome = FileScanner().scan(root: resolved.root.url, filter: resolved.root.filter)
    var scannedCount = 0
    var hashes: [RelativePath: String] = [:]
    if case .files(let files) = outcome {
      scannedCount = files.count
      for path in Planner.pathsNeedingContent(
        scan: files, state: rootState, convertToDocs: resolved.root.convertToDocs)
      {
        if case .content(let content) = await environment.reader.read(
          resolved.root.url.appending(path: path.value))
        {
          hashes[path] = content.hash
        }
      }
    }
    let plan = Planner.plan(
      scan: outcome, state: rootState, contentHashes: hashes,
      convertToDocs: resolved.root.convertToDocs)
    for line in PlanRenderer.render(plan, scannedCount: scannedCount) { environment.out(line) }
    return 0
  }

  private func sync(_ path: String) async throws -> Int32 {
    let resolved = try resolve(path)
    guard try requireFolder(resolved) else { return 1 }
    let drive = try await environment.makeDrive()
    let config = try loadConfig()
    let engine = SyncEngine(
      drive: drive, stateStore: JSONFileStore(url: resolved.stateFile),
      updateStrategy: config.updateStrategy, driveFolderName: config.driveFolderName)
    let report = await engine.reconcile(resolved.root)
    for line in ReportRenderer.render(report, rootName: resolved.root.displayName) {
      environment.out(line)
    }
    return ReportRenderer.isSuccess(report) ? 0 : 1
  }

  private func rebuildState(_ path: String?) async throws -> Int32 {
    let targets: [ResolvedRoot]
    if let path {
      targets = [try resolve(path)]
    } else {
      let config = try loadConfig()
      guard !config.roots.isEmpty else {
        environment.out("The app has no roots configured; pass a folder path.")
        return 0
      }
      targets = config.roots.map {
        ResolvedRoot(root: $0, isTemporary: false, stateFile: environment.paths.stateFile)
      }
    }
    let drive = try await environment.makeDrive()
    var failed = false
    for target in targets {
      let engine = SyncEngine(
        drive: drive, stateStore: JSONFileStore(url: target.stateFile),
        updateStrategy: try loadConfig().updateStrategy)
      do {
        try await engine.rebuildState(for: target.root)
        let count = await engine.status(of: target.root.id).mirroredFiles
        environment.out("Rebuilt state for '\(target.root.displayName)': \(count) files found")
      } catch {
        failed = true
        environment.err("Couldn't rebuild '\(target.root.displayName)': \(error)")
      }
    }
    return failed ? 1 : 0
  }

  // MARK: - Helpers

  private func loadConfig() throws -> MirrorConfig {
    switch JSONFileStore<MirrorConfig>(url: environment.paths.configFile).load() {
    case .loaded(let config): return config
    case .missing: return MirrorConfig()
    case .corrupt(let message): throw CLIError.message(message)
    }
  }

  private func resolve(_ path: String) throws -> ResolvedRoot {
    let resolved = RootResolver.resolve(
      path: path, config: try loadConfig(), paths: environment.paths)
    environment.out(
      resolved.isTemporary
        ? "Using a temporary root '\(resolved.root.displayName)' (not in the app's config); "
          + "state is in \(RootResolver.temporaryStateFileName)."
        : "Using root '\(resolved.root.displayName)' from the app's config.")
    return resolved
  }

  /// A typo'd path must not create a Drive folder for a root that can't exist.
  private func requireFolder(_ resolved: ResolvedRoot) throws -> Bool {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: resolved.root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    {
      return true
    }
    environment.err("mirrorctl: \(resolved.root.path) is not a folder.")
    return false
  }
}

enum CLIError: Error, CustomStringConvertible {
  case message(String)
  var description: String {
    switch self {
    case .message(let text): text
    }
  }
}
