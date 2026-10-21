import Foundation
import Testing

@testable import MirrorCore

@Suite struct StatusDocTests {
  private func content(
    failures: [RelativePath: String] = [:], held: Int = 0, heldPaths: [String] = [],
    machine: String? = "Kyle's MacBook Pro", converts: Bool = true,
    strategy: UpdateStrategy = .inPlace, duration: TimeInterval = 2.4
  ) -> StatusDoc.Content {
    StatusDoc.Content(
      rootName: "Notes", lastSuccessfulSync: Date(timeIntervalSince1970: 1_800_000_000),
      mirroredFiles: 42, failures: failures, heldDeletions: held,
      heldDeletionPaths: heldPaths.map { try! RelativePath($0) }, waitingForDownload: 0,
      changes: .init(created: 3, updated: 1, moved: 2, trashed: 0), duration: duration,
      machineName: machine, updateStrategy: strategy, convertsToDocs: converts)
  }

  private func render(_ content: StatusDoc.Content) -> String {
    StatusDoc.markdown(
      content, timeZone: TimeZone(identifier: "America/Los_Angeles")!,
      locale: Locale(identifier: "en_US_POSIX")
    )
    // Newer ICU puts a narrow no-break space before AM/PM; keep the expectations typeable.
    .replacingOccurrences(of: "\u{202F}", with: " ")
  }

  @Test func describesTheLastSyncAndHowFilesAreStored() {
    #expect(
      render(content()) == """
        # Drive Mirror sync status: Notes

        This Doc is maintained by Drive Mirror, which mirrors Markdown notes from the owner's iCloud Drive into this folder. The notes on iCloud are the source of truth.

        - Last successful sync: Friday, January 15, 2027 at 12:00:00 AM PST (2027-01-15T08:00:00Z)
        - Last sync took: 2 seconds, on Kyle's MacBook Pro
        - Changed in the last sync: 3 created, 1 updated, 2 moved, 0 trashed
        - Mirrored files: 42
        - Files are stored as: Google Docs, converted from Markdown
        - Update strategy: in place (edits keep the same file, so links to it keep working)
        - Failing files: none

        """)
  }

  @Test func reflectsPlainFilesAndTheReplaceStrategy() {
    let text = render(content(machine: nil, converts: false, strategy: .replace, duration: 0.2))
    #expect(text.contains("- Last sync took: under a second\n"))
    #expect(text.contains("- Files are stored as: plain Markdown files, not converted\n"))
    #expect(text.contains("- Update strategy: replace (each edit makes a new copy"))
  }

  @Test func listsHeldDeletionPathsAndCountsTheRest() {
    let paths = (0..<20).map { "old/n\($0).md" }
    let text = render(content(held: 27, heldPaths: paths))
    #expect(text.contains("- Deletions on hold: 27 mirrored files would be trashed"))
    #expect(text.contains("    - `old/n0.md`\n"))
    #expect(text.contains("    - `old/n19.md`\n    - and 7 more\n"))
  }

  @Test func listsAllHeldPathsWhenTheyAllFit() {
    let text = render(content(held: 2, heldPaths: ["a.md", "b.md"]))
    #expect(text.contains("    - `a.md`\n    - `b.md`\n"))
    #expect(!text.contains("and "))
  }

  @Test func capsListedFailures() {
    let failures = Dictionary(
      uniqueKeysWithValues: (0..<23).map { (try! RelativePath("f\($0).md"), "boom") })
    let text = render(content(failures: failures))
    #expect(text.contains("- Failing files: 23"))
    #expect(text.contains("    - and 3 more"))
  }
}
