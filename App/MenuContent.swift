import MirrorCore
import SwiftUI

struct MenuContent: View {
  let model: MenuViewModel
  @Environment(\.openSettings) private var openSettings

  var body: some View {
    Text(model.lastSyncText)
    if let notice = model.accountNotice {
      Text(notice)
    }

    if !model.rootLines.isEmpty {
      Divider()
      ForEach(model.rootLines) { line in
        Text(line.title)
        if let detail = line.detail {
          Text("    \(detail)")
        }
      }
    }

    Divider()
    Button("Sync Now") { Task { await model.syncNow() } }
      .keyboardShortcut("s")
    Button(model.pauseTitle) { Task { await model.togglePause() } }
    if model.showsApplyPendingDeletions {
      Button("Apply Pending Deletions") { Task { await model.applyPendingDeletions() } }
    }

    Divider()
    Button("Open in Google Drive") { model.openInDrive() }
      .disabled(!model.canOpenDrive)
    Button("Settings…") {
      openSettings()
      // A menu bar app isn't frontmost, so bring the Settings window forward.
      NSApplication.shared.activate()
    }
    .keyboardShortcut(",")
    Button("Copy Diagnostics") { Task { await model.copyDiagnostics() } }

    Divider()
    Button("Quit Drive Mirror") { NSApplication.shared.terminate(nil) }
      .keyboardShortcut("q")
  }
}
