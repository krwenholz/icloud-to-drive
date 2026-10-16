import Foundation
import Testing

@testable import MirrorCore

@Test func driveRootFolderNameMatchesPlan() {
  #expect(AppIdentity.driveRootFolderName == "iCloud Mirror")
}

@Test func fixturesAreBundled() throws {
  let url = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
  #expect(FileManager.default.fileExists(atPath: url.path))
}
