import CoreServices
import Foundation
import Testing
import os

@testable import MirrorCore

@Suite struct EventPathMapperTests {
  private let a = UUID()
  private let b = UUID()
  private var roots: [(id: UUID, path: String)] { [(a, "/data/notes"), (b, "/data/other")] }
  private let noFlags = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)

  @Test func mapsEventToRootAndRelativePath() {
    let event = EventPathMapper.map(
      eventPath: "/data/notes/sub/x.md", flags: noFlags, roots: roots)
    #expect(
      event == FolderEvent(root: a, path: try? RelativePath("sub/x.md"), needsFullReconcile: false))
  }

  @Test func rootItselfNeedsFullReconcile() {
    let event = EventPathMapper.map(eventPath: "/data/notes", flags: noFlags, roots: roots)
    #expect(event == FolderEvent(root: a, path: nil, needsFullReconcile: true))
  }

  @Test func unrelatedAndPrefixSiblingPathsDoNotMap() {
    #expect(EventPathMapper.map(eventPath: "/elsewhere/x.md", flags: noFlags, roots: roots) == nil)
    #expect(
      EventPathMapper.map(eventPath: "/data/notes2/x.md", flags: noFlags, roots: roots) == nil)
  }

  @Test(arguments: [
    kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
    kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagEventIdsWrapped,
    kFSEventStreamEventFlagRootChanged,
  ])
  func lossFlagsNeedFullReconcile(flag: Int) {
    let event = EventPathMapper.map(
      eventPath: "/data/notes/x.md", flags: FSEventStreamEventFlags(flag), roots: roots)
    #expect(event?.needsFullReconcile == true)
    #expect(event?.path?.value == "x.md")
  }

  @Test func normalizesNFDEventPaths() {
    let event = EventPathMapper.map(
      eventPath: "/data/notes/cafe\u{0301}.md", flags: noFlags, roots: roots)
    #expect(event?.path?.value == "caf\u{00E9}.md")
  }

  @Test func nestedRootPrefersTheDeeperRoot() {
    let inner = UUID()
    let nested = roots + [(inner, "/data/notes/inner")]
    let event = EventPathMapper.map(
      eventPath: "/data/notes/inner/y.md", flags: noFlags, roots: nested)
    #expect(event?.root == inner)
  }
}

@Suite struct FolderWatcherSmokeTests {
  // Real FSEvents timing; kept generous, polled rather than slept for a fixed time.
  @Test func reportsAFileCreatedInsideAWatchedRoot() async throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let id = UUID()
    let seen = OSAllocatedUnfairLock(initialState: [FolderEvent]())
    let watcher = FolderWatcher(latency: 0.2)
    await watcher.start(roots: [WatchedRoot(id: id, url: dir.url)]) { events in
      seen.withLock { $0.append(contentsOf: events) }
    }
    // FSEvents needs a moment before the stream is live, so retry the write while polling.
    let deadline = ContinuousClock.now + .seconds(10)
    var found = false
    var attempt = 0
    while ContinuousClock.now < deadline, !found {
      try dir.write("smoke\(attempt).md")
      attempt += 1
      try await Task.sleep(for: .milliseconds(300))
      found = seen.withLock { events in
        events.contains { $0.root == id && $0.path?.value.hasPrefix("smoke") == true }
      }
    }
    await watcher.stop()
    #expect(found)
  }
}
