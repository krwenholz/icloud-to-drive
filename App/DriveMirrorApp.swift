import MirrorCore
import SwiftUI

@main
struct DriveMirrorApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent(model: model.menu)
    } label: {
      MenuBarIcon(model: model.menu)
        .task { await model.start() }
    }

    Settings {
      SettingsView(model: model.settings)
    }
  }
}

private struct MenuBarIcon: View {
  let model: MenuViewModel

  var body: some View {
    Image(systemName: model.overallState.symbolName)
      .accessibilityLabel(AppIdentity.displayName)
  }
}
