import CoreServices
import Foundation

public struct WatchedRoot: Equatable, Sendable {
  public var id: UUID
  public var url: URL
  public init(id: UUID, url: URL) {
    self.id = id
    self.url = url
  }
}

public struct FolderEvent: Equatable, Sendable {
  public var root: UUID
  /// Nil when the event concerns the root itself or can't be expressed as a relative path.
  public var path: RelativePath?
  public var needsFullReconcile: Bool

  public init(root: UUID, path: RelativePath?, needsFullReconcile: Bool) {
    self.root = root
    self.path = path
    self.needsFullReconcile = needsFullReconcile
  }
}

/// Maps raw FSEvents paths to roots. Pure so it can be tested without a stream.
public enum EventPathMapper {
  /// Flags meaning the stream may have lost events, so only a full scan can be trusted.
  static let lossFlags: FSEventStreamEventFlags =
    FSEventStreamEventFlags(
      kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged)

  /// Both `eventPath` and the roots' paths must already be symlink-resolved.
  public static func map(
    eventPath: String, flags: FSEventStreamEventFlags, roots: [(id: UUID, path: String)]
  ) -> FolderEvent? {
    let normalized = eventPath.precomposedStringWithCanonicalMapping
    // Longest match wins so a root nested inside another still gets its own events.
    let candidates = roots.compactMap { root -> (id: UUID, path: String)? in
      let rootPath = root.path.precomposedStringWithCanonicalMapping
      return normalized == rootPath || normalized.hasPrefix(rootPath + "/")
        ? (root.id, rootPath) : nil
    }
    guard let match = candidates.max(by: { $0.path.count < $1.path.count }) else { return nil }
    let full = flags & lossFlags != 0
    if normalized == match.path {
      return FolderEvent(root: match.id, path: nil, needsFullReconcile: true)
    }
    let relative = String(normalized.dropFirst(match.path.count + 1))
    guard let path = try? RelativePath(relative) else {
      return FolderEvent(root: match.id, path: nil, needsFullReconcile: true)
    }
    return FolderEvent(root: match.id, path: path, needsFullReconcile: full)
  }
}

/// One FSEvents stream over all roots, with file-level events.
public actor FolderWatcher {
  /// Held by the stream's C callback, which can't capture anything.
  private final class CallbackBox: Sendable {
    let roots: [(id: UUID, path: String)]
    let handler: @Sendable ([FolderEvent]) -> Void
    init(roots: [(id: UUID, path: String)], handler: @escaping @Sendable ([FolderEvent]) -> Void) {
      self.roots = roots
      self.handler = handler
    }
  }

  private let latency: TimeInterval
  private let queue = DispatchQueue(label: "FolderWatcher", qos: .utility)
  private var stream: FSEventStreamRef?

  public init(latency: TimeInterval = 2) {
    self.latency = latency
  }

  /// Replaces any running stream. `handler` is called on a background queue.
  public func start(
    roots: [WatchedRoot], handler: @escaping @Sendable ([FolderEvent]) -> Void
  ) {
    stop()
    guard !roots.isEmpty else { return }
    let resolved = roots.map { (id: $0.id, path: $0.url.resolvingSymlinksInPath().path) }
    let box = CallbackBox(roots: resolved, handler: handler)
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passRetained(box).toOpaque(), retain: nil,
      release: { info in
        if let info { Unmanaged<CallbackBox>.fromOpaque(info).release() }
      },
      copyDescription: nil)

    let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
      guard let info else { return }
      let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
      let paths = unsafeBitCast(paths, to: NSArray.self)
      var events: [FolderEvent] = []
      for index in 0..<count {
        guard let raw = paths[index] as? String else { continue }
        // Resolve the same way the roots were, since `/var` and `/private/var` both occur.
        let path = URL(fileURLWithPath: raw).resolvingSymlinksInPath().path
        if let event = EventPathMapper.map(eventPath: path, flags: flags[index], roots: box.roots) {
          events.append(event)
        }
      }
      if !events.isEmpty { box.handler(events) }
    }

    let flags = FSEventStreamCreateFlags(
      kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, roots.map { $0.url.resolvingSymlinksInPath().path } as CFArray,
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
    else {
      Unmanaged.passUnretained(box).release()
      return
    }
    FSEventStreamSetDispatchQueue(stream, queue)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  public func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
