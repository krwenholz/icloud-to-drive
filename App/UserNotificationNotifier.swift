import MirrorCore
import UserNotifications

/// Delivers problem notifications through `UNUserNotificationCenter`.
struct UserNotificationNotifier: ProblemNotifying {
  /// Asks once for permission to show alerts. If the owner says no, `notify` is a no-op:
  /// the menu bar icon and menu still show every problem.
  func requestAuthorization() async {
    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert])
  }

  func notify(title: String, body: String, id: String) async {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    // Reusing the identifier replaces an earlier notification for the same problem.
    let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
    try? await UNUserNotificationCenter.current().add(request)
  }
}
