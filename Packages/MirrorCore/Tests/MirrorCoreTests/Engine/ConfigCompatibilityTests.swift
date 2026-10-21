import Foundation
import Testing

@testable import MirrorCore

/// Config and state files written by earlier versions must keep loading.
@Suite struct ConfigCompatibilityTests {
  @Test func configWithoutNewFieldsGetsDefaults() throws {
    let json = #"{"roots":[],"updateStrategy":"replace"}"#
    let config = try JSONDecoder().decode(MirrorConfig.self, from: Data(json.utf8))
    #expect(config.updateStrategy == .replace)
    #expect(config.driveFolderName == AppIdentity.driveRootFolderName)
  }

  @Test func fullSyncIntervalDefaultsToAnHourAndToleratesUnknownValues() throws {
    func decode(_ json: String) throws -> MirrorConfig {
      try JSONDecoder().decode(MirrorConfig.self, from: Data(json.utf8))
    }
    #expect(try decode(#"{"roots":[]}"#).fullSyncInterval == .oneHour)
    #expect(try decode(#"{"fullSyncInterval":"sixHours"}"#).fullSyncInterval == .sixHours)
    #expect(try decode(#"{"fullSyncInterval":"every-blue-moon"}"#).fullSyncInterval == .oneHour)
    #expect(
      FullSyncInterval.allCases.map(\.duration) == [.seconds(900), .seconds(3600), .seconds(21600)])
  }

  @Test func blankFolderNameFallsBackToTheDefault() {
    #expect(MirrorConfig.normalizedDriveFolderName("  \n") == "iCloud Mirror")
    #expect(MirrorConfig.normalizedDriveFolderName(" Claude ") == "Claude")
  }

  @Test func stateFromBeforeFolderNamesAssumesTheDefaultName() throws {
    let json = #"{"version":1,"mirrorFolderID":"m1","roots":{}}"#
    let state = try JSONDecoder().decode(MirrorState.self, from: Data(json.utf8))
    #expect(state.mirrorFolderID == "m1")
    #expect(state.mirrorFolderName == "iCloud Mirror")
  }
}
