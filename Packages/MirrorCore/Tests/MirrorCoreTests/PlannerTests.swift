import Foundation
import Testing

@testable import MirrorCore

/// Builds scans, state, and hashes for planner scenarios. Content is identified by a short
/// string; its "hash" is the string itself, which keeps expectations readable.
private struct Scenario {
  var scan: [ScannedFile] = []
  var hashes: [RelativePath: String] = [:]
  var state = RootState()
  static let then = Date(timeIntervalSince1970: 1_000)
  static let now = Date(timeIntervalSince1970: 2_000)

  init(synced: [String: String] = [:], folders: [String] = []) {
    state.folderID = "root"
    for (path, content) in synced {
      let rel = try! RelativePath(path)
      state.files[rel] = FileRecord(
        fileID: "id-\(path)", contentHash: content, size: Int64(content.count), modified: Self.then)
      scan.append(ScannedFile(path: rel, size: Int64(content.count), modified: Self.then))
    }
    for folder in folders { state.folders[folder] = "folder-\(folder)" }
  }

  /// Puts a file on disk with fresh metadata and makes its content available.
  mutating func write(_ path: String, _ content: String, modified: Date = now) {
    let rel = try! RelativePath(path)
    scan.removeAll { $0.path == rel }
    scan.append(ScannedFile(path: rel, size: Int64(content.count), modified: modified))
    hashes[rel] = content
  }

  mutating func delete(_ path: String) {
    scan.removeAll { $0.path.value == path }
  }

  func plan(convertToDocs: Bool = true, allowMassDeletion: Bool = false) -> SyncPlan {
    let needed = Set(
      Planner.pathsNeedingContent(scan: scan, state: state, convertToDocs: convertToDocs))
    return Planner.plan(
      scan: .files(scan), state: state, contentHashes: hashes.filter { needed.contains($0.key) },
      convertToDocs: convertToDocs, allowMassDeletion: allowMassDeletion)
  }
}

private func file(_ path: String, _ content: String, modified: Date = Scenario.now) -> ScannedFile {
  ScannedFile(path: try! RelativePath(path), size: Int64(content.count), modified: modified)
}

private func path(_ raw: String) -> RelativePath { try! RelativePath(raw) }

struct PlannerTests {
  @Test func importsNestedTreeWithFoldersFirst() {
    var scenario = Scenario()
    scenario.write("top.md", "t")
    scenario.write("a/b/deep.md", "d")
    scenario.write("a/mid.md", "m")
    scenario.write("z/last.md", "l")

    #expect(
      scenario.plan().operations == [
        .createFolder(directory: "a"),
        .createFolder(directory: "z"),
        .createFolder(directory: "a/b"),
        .createDoc(file("a/b/deep.md", "d"), contentHash: "d"),
        .createDoc(file("a/mid.md", "m"), contentHash: "m"),
        .createDoc(file("top.md", "t"), contentHash: "t"),
        .createDoc(file("z/last.md", "l"), contentHash: "l"),
      ])
  }

  @Test func unchangedFilesAreNotRead() {
    let scenario = Scenario(synced: ["a.md": "one", "x/b.md": "two"], folders: ["x"])
    #expect(Planner.pathsNeedingContent(scan: scenario.scan, state: scenario.state).isEmpty)
    #expect(scenario.plan() == SyncPlan())
  }

  @Test func editUpdatesTheExistingDoc() {
    var scenario = Scenario(synced: ["a.md": "one"])
    scenario.write("a.md", "one, edited")
    #expect(
      Planner.pathsNeedingContent(scan: scenario.scan, state: scenario.state) == [path("a.md")])
    #expect(
      scenario.plan().operations == [
        .updateDoc(file("a.md", "one, edited"), fileID: "id-a.md", contentHash: "one, edited")
      ])
  }

  @Test func touchedFileWithSameContentOnlyRecordsMetadata() {
    var scenario = Scenario(synced: ["a.md": "one"])
    scenario.write("a.md", "one")
    #expect(scenario.plan().operations == [.recordUnchanged(file("a.md", "one"))])
  }

  @Test func deleteTrashesTheDoc() {
    var scenario = Scenario(synced: ["a.md": "one", "b.md": "two"])
    scenario.delete("a.md")
    #expect(scenario.plan().operations == [.trashDoc(path("a.md"), fileID: "id-a.md")])
  }

  @Test func renameKeepsTheFileID() {
    var scenario = Scenario(synced: ["old.md": "same"])
    scenario.delete("old.md")
    scenario.write("new.md", "same")
    #expect(
      scenario.plan().operations == [
        .moveDoc(from: path("old.md"), to: file("new.md", "same"), fileID: "id-old.md")
      ])
  }

  @Test func moveBetweenSubfoldersCreatesTheDestinationFolder() {
    var scenario = Scenario(synced: ["x/note.md": "same"], folders: ["x"])
    scenario.delete("x/note.md")
    scenario.write("y/note.md", "same")
    #expect(
      scenario.plan().operations == [
        .createFolder(directory: "y"),
        .moveDoc(from: path("x/note.md"), to: file("y/note.md", "same"), fileID: "id-x/note.md"),
      ])
  }

  @Test func moveWithEditIsTrashPlusCreate() {
    var scenario = Scenario(synced: ["old.md": "before"])
    scenario.delete("old.md")
    scenario.write("new.md", "after")
    #expect(
      scenario.plan().operations == [
        .createDoc(file("new.md", "after"), contentHash: "after"),
        .trashDoc(path("old.md"), fileID: "id-old.md"),
      ])
  }

  @Test func duplicateContentPrefersSourceWithSameFileName() {
    var scenario = Scenario(
      synced: ["a/note.md": "same", "b/other.md": "same"], folders: ["a", "b"])
    scenario.delete("a/note.md")
    scenario.delete("b/other.md")
    scenario.write("c/note.md", "same")
    let operations = scenario.plan().operations
    #expect(
      operations.contains(
        .moveDoc(from: path("a/note.md"), to: file("c/note.md", "same"), fileID: "id-a/note.md")))
    #expect(operations.contains(.trashDoc(path("b/other.md"), fileID: "id-b/other.md")))
  }

  @Test func filesWithoutContentAreDeferredNotDeleted() {
    var scenario = Scenario(synced: ["a.md": "one"])
    scenario.scan = [file("a.md", "changed"), file("new.md", "n")]
    let plan = scenario.plan()
    #expect(plan.operations.isEmpty)
    #expect(plan.deferred == [path("a.md"), path("new.md")])
  }

  @Test func excludedFileIsNeverPlanned() {
    // Exclusion happens in the scan; a filtered scan simply doesn't contain the file.
    var scenario = Scenario()
    scenario.write("keep.md", "k")
    scenario.write("archive/old.md", "o")
    let filter = PathFilter(exclude: [GlobPattern("archive/")])
    scenario.scan = scenario.scan.filter { filter.includes($0.path) }
    #expect(scenario.plan().operations == [.createDoc(file("keep.md", "k"), contentHash: "k")])
  }

  @Test func newlyExcludedFileIsTrashed() {
    var scenario = Scenario(synced: ["keep.md": "k", "archive/old.md": "o"], folders: ["archive"])
    let filter = PathFilter(exclude: [GlobPattern("archive/")])
    scenario.scan = scenario.scan.filter { filter.includes($0.path) }
    #expect(
      scenario.plan().operations == [.trashDoc(path("archive/old.md"), fileID: "id-archive/old.md")]
    )
  }

  @Test func nfdAndNFCNamesAreTheSameFile() {
    var scenario = Scenario(synced: ["caf\u{00E9}.md": "c"])
    scenario.scan = [
      ScannedFile(path: try! RelativePath("cafe\u{0301}.md"), size: 1, modified: Scenario.then)
    ]
    #expect(scenario.plan() == SyncPlan())
  }

  @Test func missingRootPlansNothing() {
    let scenario = Scenario(synced: ["a.md": "one", "b.md": "two"])
    let plan = Planner.plan(
      scan: .unavailable(reason: "folder not found"), state: scenario.state, contentHashes: [:])
    #expect(plan.operations.isEmpty)
    #expect(plan.heldDeletions.isEmpty)
    #expect(plan.attention == .rootUnavailable("folder not found"))
  }

  @Test func massDeletionGuardHoldsTrashes() {
    let synced = Dictionary(uniqueKeysWithValues: (0..<40).map { ("n\($0).md", "c\($0)") })
    var scenario = Scenario(synced: synced)
    for i in 0..<11 { scenario.delete("n\(i).md") }
    scenario.write("new.md", "fresh")

    let plan = scenario.plan()
    #expect(plan.operations == [.createDoc(file("new.md", "fresh"), contentHash: "fresh")])
    #expect(plan.heldDeletions.count == 11)
    #expect(plan.attention == .massDeletion(pending: 11, mirrored: 40))

    let applied = scenario.plan(allowMassDeletion: true)
    #expect(applied.heldDeletions.isEmpty)
    #expect(applied.attention == nil)
    #expect(
      applied.operations.filter { if case .trashDoc = $0 { true } else { false } }.count == 11)
  }

  @Test func massDeletionGuardNeedsBothThresholds() {
    // 25% but only 10 files: not enough in absolute terms.
    let forty = Dictionary(uniqueKeysWithValues: (0..<40).map { ("n\($0).md", "c\($0)") })
    var small = Scenario(synced: forty)
    for i in 0..<10 { small.delete("n\(i).md") }
    #expect(small.plan().attention == nil)
    #expect(small.plan().operations.count == 10)

    // More than 10 files but only 11% of the root.
    let hundred = Dictionary(uniqueKeysWithValues: (0..<100).map { ("n\($0).md", "c\($0)") })
    var large = Scenario(synced: hundred)
    for i in 0..<11 { large.delete("n\(i).md") }
    #expect(large.plan().attention == nil)
    #expect(large.plan().operations.count == 11)
  }

  @Test func rebuiltStateHashesOnceWithoutUploading() {
    var scenario = Scenario(synced: ["a.md": "one"])
    scenario.state.files[path("a.md")]?.size = nil
    scenario.state.files[path("a.md")]?.modified = nil
    scenario.hashes[path("a.md")] = "one"
    #expect(
      scenario.plan().operations == [.recordUnchanged(file("a.md", "one", modified: Scenario.then))]
    )
  }

  @Test func filesInTheWrongFormatAreReplacedNotDeleted() {
    // Every file is mismatched; if these counted as trashes the guard would hold them all.
    let synced = Dictionary(uniqueKeysWithValues: (0..<20).map { ("n\($0).md", "c\($0)") })
    var scenario = Scenario(synced: synced)
    for (path, _) in synced { scenario.hashes[try! RelativePath(path)] = synced[path] }

    let plan = scenario.plan(convertToDocs: false)

    #expect(plan.attention == nil)
    #expect(plan.heldDeletions.isEmpty)
    #expect(plan.operations.count == 20)
    #expect(
      plan.operations.allSatisfy { if case .reformatDoc = $0 { true } else { false } })
    #expect(scenario.plan(convertToDocs: true).operations.isEmpty)
  }

  @Test func plainFilesAreLeftAloneWhenTheRootStaysPlain() {
    var scenario = Scenario(synced: ["a.md": "one"])
    scenario.state.files[path("a.md")]?.converted = false
    #expect(scenario.plan(convertToDocs: false).operations.isEmpty)
  }
}
