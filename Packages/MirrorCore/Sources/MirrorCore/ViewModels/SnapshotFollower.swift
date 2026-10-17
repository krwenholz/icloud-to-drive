import Foundation

/// Subscribes to a service's snapshots on the main actor. Returns once the first snapshot has
/// been delivered, so a view model is never shown empty after `start()`.
@MainActor
func followSnapshots(
  of service: any MirrorService, _ receive: @escaping @MainActor (MirrorSnapshot) -> Void
) async -> Task<Void, Never> {
  let stream = await service.snapshots()
  var listener: Task<Void, Never>?
  await withCheckedContinuation { (ready: CheckedContinuation<Void, Never>) in
    listener = Task { @MainActor in
      var isFirst = true
      for await snapshot in stream {
        receive(snapshot)
        if isFirst {
          isFirst = false
          ready.resume()
        }
      }
      if isFirst { ready.resume() }
    }
  }
  return listener!
}
