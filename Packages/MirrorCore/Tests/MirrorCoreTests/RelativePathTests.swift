import Foundation
import Testing

@testable import MirrorCore

struct RelativePathTests {
  @Test func normalizesNFDToNFC() throws {
    let decomposed = "cafe\u{0301}.md"
    let path = try RelativePath(decomposed)
    #expect(path.value == "caf\u{00E9}.md")
    #expect(path == (try RelativePath("caf\u{00E9}.md")))
    #expect(path.pathHash == (try RelativePath("caf\u{00E9}.md")).pathHash)
  }

  @Test(arguments: [
    ("", RelativePath.ValidationError.empty),
    ("/etc/passwd", .absolute),
    ("../outside.md", .escapesRoot),
    ("notes/../../outside.md", .escapesRoot),
    ("notes//a.md", .emptyComponent),
    ("./a.md", .emptyComponent),
    ("notes/", .emptyComponent),
  ])
  func rejectsInvalidPaths(raw: String, expected: RelativePath.ValidationError) {
    #expect(throws: expected) { try RelativePath(raw) }
  }

  @Test func pathHashIsSHA256Hex() throws {
    let path = try RelativePath("projects/garden.md")
    #expect(path.pathHash == Hashing.sha256Hex("projects/garden.md"))
    #expect(path.pathHash.count == 64)
  }

  @Test func derivesTitleAndDescription() throws {
    let path = try RelativePath("projects/garden.md")
    #expect(path.docTitle == "garden")
    #expect(path.directory == "projects")
    #expect(path.docDescription(rootName: "Notes") == "Notes / projects/garden.md")
    #expect(try RelativePath("Shout.MD").docTitle == "Shout")
    #expect(try RelativePath("a.b.md").docTitle == "a.b")
    #expect(try RelativePath(".md").docTitle == ".md")
    #expect(try RelativePath("top.md").directory == "")
  }

  @Test func recoversPathFromDescription() throws {
    let path = try RelativePath("projects/garden.md")
    let description = path.docDescription(rootName: "My Notes")
    #expect(RelativePath.fromDocDescription(description, rootName: "My Notes") == path)
    #expect(RelativePath.fromDocDescription(description, rootName: "Other") == nil)
    #expect(RelativePath.fromDocDescription("My Notes / ../x.md", rootName: "My Notes") == nil)
  }

  @Test func encodesAsDictionaryKey() throws {
    let records = [try RelativePath("a/b.md"): 1]
    let json = try JSONEncoder().encode(records)
    #expect(String(decoding: json, as: UTF8.self) == #"{"a\/b.md":1}"#)
    #expect(try JSONDecoder().decode([RelativePath: Int].self, from: json) == records)
  }

  @Test func listsDirectoryAncestors() {
    #expect(directoryAndAncestors("a/b/c") == ["a", "a/b", "a/b/c"])
    #expect(directoryAndAncestors("") == [])
    #expect(parentDirectory(of: "a/b/c") == "a/b")
    #expect(parentDirectory(of: "a") == "")
  }
}
