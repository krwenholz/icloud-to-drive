import Foundation
import Testing

@testable import MirrorCore

struct DriveProbeTests {
  let clock = TestClock()

  func probe(_ drive: InMemoryDriveClient) -> DriveProbe {
    let clock = clock
    return DriveProbe(drive: drive, now: { clock.now })
  }

  @Test func passesEndToEndAndTrashesTheFolder() async throws {
    let drive = InMemoryDriveClient()
    let report = await probe(drive).run()

    #expect(report.passed, "\(report.checks.filter { !$0.passed })")
    #expect(report.recommendedStrategy == .inPlace)
    let folder = try #require(await drive.items.values.first { $0.file.isFolder })
    #expect(folder.trashed)
    #expect(folder.file.name.hasPrefix("Drive Mirror Probe 2027-"))

    let docs = await drive.items.values.filter { !$0.file.isFolder }
    #expect(docs.count == ProbeCorpus.fixtures.count)
    for doc in docs {
      let properties = doc.file.appProperties
      #expect(properties[AppPropertyKey.kind] == "doc")
      #expect(properties[AppPropertyKey.root] != nil)
      #expect(properties[AppPropertyKey.pathHash] != nil)
      #expect(properties[AppPropertyKey.contentHash] != nil)
    }
    // Front matter is stripped like the engine does before upload.
    let frontMatter = try #require(docs.first { $0.file.name == "Front matter" })
    let uploaded = String(decoding: frontMatter.content ?? Data(), as: UTF8.self)
    #expect(!uploaded.contains("tags:"))
  }

  @Test func printsOriginalAndExportedBlocks() async throws {
    let report = await probe(InMemoryDriveClient()).run()
    let text = report.render().joined(separator: "\n")
    #expect(text.contains("PASS"))
    #expect(text.contains("===== Original Markdown: Conversion sampler ====="))
    #expect(text.contains("===== Exported from the Google Doc (text/markdown) ====="))
    #expect(text.contains("| Apple | 3     |"))
    #expect(text.contains("All checks passed."))
  }

  @Test func failedUpdateRecommendsReplaceAndStillTrashes() async throws {
    let drive = InMemoryDriveClient()
    await drive.failNext {
      if case .updateFile = $0 { true } else { false }
    }
    let report = await probe(drive).run()

    #expect(!report.passed)
    #expect(report.recommendedStrategy == .replace)
    let failed = report.checks.filter { !$0.passed }.map(\.name)
    #expect(failed.contains("In-place update keeps file ID"))
    let text = report.render().joined(separator: "\n")
    #expect(text.contains("FAIL"))
    #expect(text.contains(".replace should be the update strategy"))
    let folder = try #require(await drive.items.values.first { $0.file.isFolder })
    #expect(folder.trashed)
  }

  @Test func failedFolderCreationSkipsTheRestAndTheTrash() async throws {
    let drive = InMemoryDriveClient()
    await drive.failNext {
      if case .createFolder = $0 { true } else { false }
    }
    let report = await probe(drive).run()
    #expect(!report.passed)
    #expect(report.checks.contains { $0.name == "Create probe folder" && !$0.passed })
    #expect(!report.checks.contains { $0.name == "Trash probe folder" })
    #expect(await drive.items.isEmpty)
  }

  @Test func missingEmailFails() async {
    let drive = InMemoryDriveClient()
    await drive.setEmail(nil)
    let report = await probe(drive).run()
    #expect(report.checks.contains { $0.name == "About returns email" && !$0.passed })
  }

  @Test func probeCommandExitsNonZeroOnFailure() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    await harness.drive.setEmail(nil)
    #expect(await harness.runner().run(["probe"]) == 1)
    #expect(harness.out.text.contains("FAIL"))
  }

  /// Real Drive, real Keychain token, real client file. Skipped unless asked for.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["LIVE_DRIVE"] == "1"))
  func liveProbePasses() async throws {
    let environment = CLIEnvironment.live()
    let drive = try await environment.makeDrive()
    let report = await DriveProbe(drive: drive).run()
    for line in report.render() { print(line) }
    #expect(report.passed)
  }
}
