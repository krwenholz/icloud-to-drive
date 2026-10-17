import Foundation
import Testing

@testable import MirrorCore

@Suite struct FileReaderTests {
  @Test func readsANormalFile() async throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let file = try dir.write("a.md", "# Title\n")
    let result = await CoordinatedFileReader().read(file)
    #expect(result == .content(PreparedContent(markdown: Data("# Title\n".utf8))))
  }

  @Test func emptyFileBecomesNewline() async throws {
    let dir = try TempDirectory()
    defer { dir.remove() }
    let file = try dir.write("empty.md", "")
    guard case .content(let content) = await CoordinatedFileReader().read(file) else {
      Issue.record("expected content")
      return
    }
    #expect(content.data == Data("\n".utf8))
  }

  @Test func missingFileFails() async {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID()).md")
    guard case .failed = await CoordinatedFileReader().read(url) else {
      Issue.record("expected failure")
      return
    }
  }

  @Test func blockedReadTimesOut() async {
    let gate = DispatchSemaphore(value: 0)
    let reader = CoordinatedFileReader(timeout: 0.05) { _ in
      gate.wait()
      return .success(Data())
    }
    let result = await reader.read(URL(fileURLWithPath: "/tmp/ignored.md"))
    gate.signal()
    guard case .failed(let message) = result else {
      Issue.record("expected failure")
      return
    }
    #expect(message.hasPrefix("timed out"))
  }
}
