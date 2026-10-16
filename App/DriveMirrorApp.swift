import MirrorCore
import SwiftUI

@main
struct DriveMirrorApp: App {
  var body: some Scene {
    MenuBarExtra(AppIdentity.displayName, systemImage: "arrow.triangle.2.circlepath.icloud") {
      Button("Quit") { NSApplication.shared.terminate(nil) }
    }
  }
}
