import AppKit
import MirrorCore
import ServiceManagement

/// Builds the live coordinator and the view models, and forwards system events to them.
@MainActor
final class AppModel {
  let coordinator: SyncCoordinator<ContinuousClock>
  let menu: MenuViewModel
  let settings: SettingsViewModel
  private let notifier = UserNotificationNotifier()
  private var wakeObserver: (any NSObjectProtocol)?

  init(paths: AppPaths = AppPaths()) {
    let log = MirrorLog(file: RollingLogFile(url: paths.logFile))
    coordinator = SyncCoordinator(
      .init(
        paths: paths, clock: ContinuousClock(),
        makeAuth: { config in GoogleAuth(config: config, store: KeychainTokenStore()) },
        makeEngine: { auth, strategy in
          SyncEngine(
            drive: GoogleDriveClient(tokens: auth),
            stateStore: JSONFileStore(url: paths.stateFile), updateStrategy: strategy)
        },
        lookUpEmail: { auth in try? await GoogleDriveClient(tokens: auth).userEmail() },
        openBrowser: { url in await MainActor.run { _ = NSWorkspace.shared.open(url) } },
        watcher: FolderWatcher(), log: log, notifier: notifier))
    menu = MenuViewModel(
      service: coordinator,
      copyToPasteboard: { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      },
      openURL: { NSWorkspace.shared.open($0) })
    settings = SettingsViewModel(service: coordinator, loginItem: MainAppLoginItem())
  }

  func start() async {
    await menu.start()
    await settings.start()
    await notifier.requestAuthorization()
    let coordinator = coordinator
    wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
    ) { _ in
      Task { await coordinator.handleWake() }
    }
    await coordinator.start()
  }
}

/// Launch at login through `SMAppService.mainApp`.
struct MainAppLoginItem: LoginItemControlling {
  var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

  func setEnabled(_ enabled: Bool) throws {
    if enabled {
      try SMAppService.mainApp.register()
    } else {
      try SMAppService.mainApp.unregister()
    }
  }
}
