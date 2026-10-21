import Foundation
import Testing

@testable import MirrorCore

/// Checks the exact request each `GoogleDriveClient` call sends.
struct DriveRequestGoldenTests {
  let stub = HTTPStub()
  let client: GoogleDriveClient
  static let fileJSON = #"{"id":"f1","name":"n","mimeType":"application/vnd.google-apps.document"}"#

  init() {
    client = GoogleDriveClient(
      tokens: StaticTokenProvider(), session: stub.session, makeBoundary: { "BOUNDARY" })
    stub.respond { _ in .json(200, Self.fileJSON) }
  }

  private var only: HTTPStub.Recorded {
    get throws {
      try #require(stub.requests.count == 1)
      return stub.requests[0]
    }
  }

  @Test func createDoc() async throws {
    _ = try await client.createFile(
      markdown: Data("# Garden\n\n- tomatoes\n".utf8), name: "garden", parentID: "parent-1",
      description: "Notes / projects/garden.md",
      appProperties: ["r": "ROOT-UUID", "k": "pathhash", "h": "contenthash", "t": "doc"],
      convert: true)
    try Golden.check(Golden.render(only), named: "create-doc")
  }

  @Test func createPlainFile() async throws {
    _ = try await client.createFile(
      markdown: Data("# Garden\n\n- tomatoes\n".utf8), name: "garden.md", parentID: "parent-1",
      description: "Notes / projects/garden.md",
      appProperties: ["r": "ROOT-UUID", "k": "pathhash", "h": "contenthash", "t": "doc"],
      convert: false)
    try Golden.check(Golden.render(only), named: "create-file-plain")
  }

  @Test func updateDoc() async throws {
    _ = try await client.updateFile(
      id: "doc-1", markdown: Data("# Garden\n\nEdited.\n".utf8),
      description: "Notes / projects/garden.md",
      appProperties: ["r": "ROOT-UUID", "k": "pathhash", "h": "newhash", "t": "doc"])
    try Golden.check(Golden.render(only), named: "update-doc")
  }

  @Test func createFolder() async throws {
    _ = try await client.createFolder(
      name: "projects", parentID: "root-folder", description: "Notes / projects/",
      appProperties: ["r": "ROOT-UUID", "k": "dirhash", "t": "dir"])
    try Golden.check(Golden.render(only), named: "create-folder")
  }

  @Test func moveFile() async throws {
    _ = try await client.moveFile(
      id: "doc-1", name: "renamed", description: "Notes / new/renamed.md",
      appProperties: ["r": "ROOT-UUID", "k": "newpathhash", "h": "contenthash", "t": "doc"],
      addParent: "folder-new", removeParent: "folder-old")
    try Golden.check(Golden.render(only), named: "move-file")
  }

  @Test func renameOnly() async throws {
    _ = try await client.moveFile(
      id: "doc-1", name: "renamed", description: nil, appProperties: nil, addParent: nil,
      removeParent: nil)
    try Golden.check(Golden.render(only), named: "rename-file")
  }

  @Test func trashFile() async throws {
    try await client.trashFile(id: "doc-1")
    try Golden.check(Golden.render(only), named: "trash-file")
  }

  @Test func listFiles() async throws {
    stub.respond { _ in .json(200, #"{"files":[]}"#) }
    _ = try await client.listFiles(root: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!)
    try Golden.check(Golden.render(only), named: "list-files")
  }

  @Test func userEmail() async throws {
    stub.respond { _ in .json(200, #"{"user":{"emailAddress":"me@example.com"}}"#) }
    #expect(try await client.userEmail() == "me@example.com")
    try Golden.check(Golden.render(only), named: "about")
  }

  @Test func escapesQuotesInQueries() {
    #expect(GoogleDriveClient.escapeQuery(#"it's a \ test"#) == #"it\'s a \\ test"#)
    let url = GoogleDriveClient.url("https://x.test/files", ["q": "a+b c'd"])
    #expect(url.absoluteString == "https://x.test/files?q=a%2Bb%20c%27d")
  }
}
