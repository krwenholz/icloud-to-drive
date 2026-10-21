import Foundation
import Testing

@testable import MirrorCore

struct InMemoryDriveClientTests {
  @Test func buildsATreeAndHidesTrash() async throws {
    let drive = InMemoryDriveClient()
    let top = try await drive.createFolder(
      name: "iCloud Mirror", parentID: nil, description: nil, appProperties: [:])
    let sub = try await drive.createFolder(
      name: "projects", parentID: top.id, description: nil, appProperties: ["r": "x"])
    let doc = try await drive.createFile(
      markdown: Data("hi".utf8), name: "garden", parentID: sub.id, description: "d",
      appProperties: ["r": "x"], convert: true)
    #expect(await drive.treeListing(under: top.id) == ["projects/", "projects/garden"])
    #expect(try await drive.listFiles(appProperty: "r", value: "x").count == 2)

    try await drive.trashFile(id: doc.id)
    #expect(await drive.treeListing(under: top.id) == ["projects/"])
    await #expect(throws: DriveError.self) {
      try await drive.updateFile(id: doc.id, markdown: Data(), description: "", appProperties: [:])
    }
  }

  @Test func injectsFailuresOnMatchingCalls() async throws {
    let drive = InMemoryDriveClient()
    let top = try await drive.createFolder(
      name: "top", parentID: nil, description: nil, appProperties: [:])
    await drive.failNext(where: { if case .createFile(name: "b") = $0 { true } else { false } })

    _ = try await drive.createFile(
      markdown: Data(), name: "a", parentID: top.id, description: "", appProperties: [:],
      convert: true)
    await #expect(throws: DriveError.self) {
      try await drive.createFile(
        markdown: Data(), name: "b", parentID: top.id, description: "", appProperties: [:],
        convert: true)
    }
    _ = try await drive.createFile(
      markdown: Data(), name: "b", parentID: top.id, description: "", appProperties: [:],
      convert: true)
    #expect(await drive.treeListing(under: top.id) == ["a", "b"])
  }

  @Test func rejectsMissingParents() async throws {
    let drive = InMemoryDriveClient()
    await #expect(throws: DriveError.self) {
      try await drive.createFile(
        markdown: Data(), name: "a", parentID: "nope", description: "", appProperties: [:],
        convert: true)
    }
  }
}
