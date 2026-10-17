import Foundation
import Testing

@testable import MirrorCore

struct ClientFileTests {
  static let sample = """
    {"installed":{"client_id":"abc.apps.googleusercontent.com","client_secret":"shh",
    "auth_uri":"https://accounts.google.com/o/oauth2/auth",
    "token_uri":"https://oauth2.googleapis.com/token","redirect_uris":["http://localhost"]}}
    """

  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func importThenLoadRoundTrips() throws {
    let support = try tempDirectory()
    let source = try tempDirectory().appending(path: "download.json")
    try Data(Self.sample.utf8).write(to: source)

    let imported = try ClientFile.importFile(from: source, applicationSupport: support)
    let loaded = try ClientFile.load(applicationSupport: support)

    #expect(imported == loaded)
    #expect(loaded.clientID == "abc.apps.googleusercontent.com")
    #expect(loaded.clientSecret == "shh")
    #expect(loaded.tokenURI.absoluteString == "https://oauth2.googleapis.com/token")
    let path = ClientFile.fileURL(applicationSupport: support).path
    #expect(path.hasSuffix("/Drive Mirror/google-client.json"))
    let permissions = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
    #expect(permissions as? Int == 0o600)
  }

  @Test func loadWithoutFileThrowsClientFileMissing() throws {
    let support = try tempDirectory()
    #expect(throws: AuthError.clientFileMissing(ClientFile.fileURL(applicationSupport: support))) {
      try ClientFile.load(applicationSupport: support)
    }
  }

  @Test func invalidImportIsRejectedAndLeavesExistingFileAlone() throws {
    let support = try tempDirectory()
    let good = try tempDirectory().appending(path: "good.json")
    try Data(Self.sample.utf8).write(to: good)
    try ClientFile.importFile(from: good, applicationSupport: support)

    let bad = try tempDirectory().appending(path: "bad.json")
    try Data(#"{"web":{"client_id":"x"}}"#.utf8).write(to: bad)
    #expect(throws: (any Error).self) {
      try ClientFile.importFile(from: bad, applicationSupport: support)
    }
    #expect(
      try ClientFile.load(applicationSupport: support).clientID == "abc.apps.googleusercontent.com")
  }

  @Test func descriptionRedactsSecret() {
    #expect(!"\(testConfig)".contains("client-secret"))
  }
}
