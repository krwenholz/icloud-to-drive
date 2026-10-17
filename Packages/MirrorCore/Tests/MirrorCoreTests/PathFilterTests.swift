import Testing

@testable import MirrorCore

struct GlobPatternTests {
  @Test(arguments: [
    ("**/*.md", "a.md", true),
    ("**/*.md", "x/y/z/a.md", true),
    ("**/*.md", "a.txt", false),
    ("**/*.md", "a.md/b.txt", false),
    ("*.md", "a.md", true),
    ("*.md", "x/a.md", false),
    ("notes/*.md", "notes/a.md", true),
    ("notes/*.md", "notes/sub/a.md", false),
    ("notes/**/*.md", "notes/a.md", true),
    ("notes/**/*.md", "notes/sub/deeper/a.md", true),
    ("?.md", "a.md", true),
    ("?.md", "ab.md", false),
    ("?.md", "/.md", false),
    ("archive/", "archive/a.md", true),
    ("archive/", "archive/sub/a.md", true),
    ("archive/", "archived/a.md", false),
    ("**/drafts/**", "x/drafts/a.md", true),
    ("**/drafts/**", "drafts/a.md", true),
    ("*draft*", "my-draft-1.md", true),
    ("**/*.md", "UPPER.MD", true),
  ])
  func matches(pattern: String, path: String, expected: Bool) {
    #expect(GlobPattern(pattern).matches(path) == expected)
  }

  @Test func matchesNFDPathAgainstNFCPattern() {
    #expect(GlobPattern("caf\u{00E9}/*.md").matches("cafe\u{0301}/a.md"))
  }

  @Test func detectsPatternsThatCoverWholeDirectories() {
    #expect(GlobPattern("archive/").matchesEverything(under: "archive"))
    #expect(GlobPattern("archive/**").matchesEverything(under: "archive"))
    #expect(!GlobPattern("archive/*").matchesEverything(under: "archive"))
    #expect(!GlobPattern("archive/").matchesEverything(under: "other"))
  }
}

struct PathFilterTests {
  let filter = PathFilter()

  @Test func includesMarkdownByDefault() throws {
    #expect(filter.includes(try RelativePath("a.md")))
    #expect(filter.includes(try RelativePath("x/y/a.md")))
    #expect(!filter.includes(try RelativePath("a.txt")))
  }

  @Test func alwaysExcludesHiddenFilesAndDirectories() throws {
    #expect(!filter.includes(try RelativePath(".hidden.md")))
    #expect(!filter.includes(try RelativePath("x/.secret/a.md")))
    #expect(!filter.includes(try RelativePath(".obsidian/notes.md")))
    #expect(!filter.includes(try RelativePath("x/.note.md.icloud")))
    let everything = PathFilter(include: [GlobPattern("**")], exclude: [])
    #expect(!everything.includes(try RelativePath(".hidden.md")))
  }

  @Test func appliesExcludePatterns() throws {
    let custom = PathFilter(exclude: [GlobPattern("archive/"), GlobPattern("**/*-draft.md")])
    #expect(!custom.includes(try RelativePath("archive/old.md")))
    #expect(!custom.includes(try RelativePath("x/idea-draft.md")))
    #expect(custom.includes(try RelativePath("x/idea.md")))
  }

  @Test func prunesExcludedAndHiddenDirectories() {
    let custom = PathFilter(exclude: [GlobPattern("archive/")])
    #expect(!custom.mayDescend(into: "archive"))
    #expect(!custom.mayDescend(into: ".git"))
    #expect(custom.mayDescend(into: "notes"))
  }
}
