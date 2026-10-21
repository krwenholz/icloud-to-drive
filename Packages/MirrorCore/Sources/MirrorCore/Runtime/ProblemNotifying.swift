import Foundation

/// Shows the owner a notification about a new problem; `UNUserNotificationCenter` in the app.
///
/// The coordinator decides when to call it (once per problem, never on success), so an
/// implementation only has to deliver. `id` is stable per problem, so delivering it again
/// replaces the earlier notification instead of stacking.
public protocol ProblemNotifying: Sendable {
  func notify(title: String, body: String, id: String) async
}
