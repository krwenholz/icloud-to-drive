import Foundation
import Testing

@testable import MirrorCore

struct PreparedContentTests {
  private func prepared(_ text: String) -> String {
    String(decoding: PreparedContent(markdown: Data(text.utf8)).data, as: UTF8.self)
  }

  @Test func stripsFrontMatter() {
    #expect(prepared("---\ntitle: x\ntags: [a]\n---\n# Body\n") == "# Body\n")
    #expect(prepared("---\ntitle: x\n...\nBody") == "Body")
    #expect(prepared("---\r\ntitle: x\r\n---\r\nBody\r\n") == "Body\r\n")
    #expect(prepared("\u{FEFF}---\na: 1\n---\nBody") == "Body")
  }

  @Test func leavesUnclosedOrMidDocumentRulesAlone() {
    #expect(prepared("---\nnot front matter\n") == "---\nnot front matter\n")
    #expect(prepared("# Title\n---\nmore\n---\n") == "# Title\n---\nmore\n---\n")
  }

  @Test func replacesEmptyContentWithNewline() {
    #expect(prepared("") == "\n")
    #expect(prepared("---\na: 1\n---\n") == "\n")
  }

  @Test func hashIgnoresFrontMatterOnlyChanges() {
    let before = PreparedContent(markdown: Data("---\nupdated: 1\n---\nBody\n".utf8))
    let after = PreparedContent(markdown: Data("---\nupdated: 2\n---\nBody\n".utf8))
    let edited = PreparedContent(markdown: Data("---\nupdated: 2\n---\nBody!\n".utf8))
    #expect(before.hash == after.hash)
    #expect(before.hash != edited.hash)
    #expect(before.hash == Hashing.sha256Hex(Data("Body\n".utf8)))
  }
}
