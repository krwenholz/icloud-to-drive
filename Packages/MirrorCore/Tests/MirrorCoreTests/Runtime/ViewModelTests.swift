import Foundation
import Testing

@testable import MirrorCore

@MainActor
struct MenuViewModelTests {
  let service = FakeMirrorService()
  var copied: [String] = []

  func makeModel(copied: CopiedBox = CopiedBox(), opened: CopiedBox = CopiedBox()) -> MenuViewModel
  {
    MenuViewModel(
      service: service, now: { Date(timeIntervalSince1970: 1_800_000_300) },
      locale: Locale(identifier: "en_US"),
      copyToPasteboard: { copied.values.append($0) },
      openURL: { opened.values.append($0.absoluteString) })
  }

  private func signedIn(_ roots: [RootSnapshot], paused: Bool = false) -> MirrorSnapshot {
    var snapshot = MirrorSnapshot()
    snapshot.account = .signedIn(email: "me@example.com")
    snapshot.roots = roots
    snapshot.isPaused = paused
    snapshot.mirrorFolderID = "folder-1"
    return snapshot
  }

  @Test func reflectsOverallState() async {
    let model = makeModel()
    await model.start()

    await service.push(signedIn([sampleRoot()]))
    #expect(await eventually { model.overallState == .idle })
    #expect(model.overallState.symbolName == "checkmark.icloud")

    await service.push(
      signedIn([sampleRoot(phase: .syncing), sampleRoot("B", phase: .error("x"))]))
    #expect(await eventually { model.overallState == .syncing })

    await service.push(signedIn([sampleRoot(phase: .error("boom"))]))
    #expect(await eventually { model.overallState == .error })

    await service.push(signedIn([sampleRoot(phase: .error("boom"))], paused: true))
    #expect(await eventually { model.overallState == .paused })
    #expect(model.pauseTitle == "Resume")
  }

  @Test func describesRootsAndLastSync() async {
    let model = makeModel()
    await service.push(
      signedIn([
        sampleRoot(),
        sampleRoot("Journal", phase: .needsAttention("12 of 20 Docs would be trashed.")),
      ]))
    await model.start()

    #expect(model.lastSyncText == "Last synced 5 minutes ago")
    #expect(model.rootLines.map(\.title) == ["Notes: 12 notes", "Journal: Needs attention"])
    #expect(model.rootLines.last?.detail == "12 of 20 Docs would be trashed.")
    #expect(model.accountNotice == nil)
  }

  @Test func showsAccountNotices() async {
    let model = makeModel()
    var snapshot = MirrorSnapshot()
    snapshot.account = .needsClientFile
    await service.push(snapshot)
    await model.start()
    #expect(model.accountNotice == "Import your Google client file in Settings.")
    #expect(model.lastSyncText == "Not synced yet")
  }

  @Test func appliesPendingDeletionsOnlyWhereHeld() async {
    let model = makeModel()
    let held = sampleRoot("Held", held: 15)
    await service.push(signedIn([sampleRoot(), held]))
    await model.start()

    #expect(model.showsApplyPendingDeletions)
    await model.applyPendingDeletions()
    #expect(await service.calls == [.applyPendingDeletions(held.id)])
  }

  @Test func forwardsActions() async {
    let copied = CopiedBox()
    let opened = CopiedBox()
    let model = makeModel(copied: copied, opened: opened)
    await service.push(signedIn([sampleRoot()]))
    await model.start()

    await model.syncNow()
    await model.togglePause()
    await model.copyDiagnostics()
    model.openInDrive()

    #expect(await service.calls == [.syncNow, .setPaused(true)])
    #expect(copied.values == ["diagnostics text"])
    #expect(opened.values == ["https://drive.google.com/drive/folders/folder-1"])
  }
}

@MainActor
final class CopiedBox {
  var values: [String] = []
}

@MainActor
struct SettingsViewModelTests {
  let service = FakeMirrorService()
  let loginItem = FakeLoginItem()

  @Test func describesAccount() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    await model.start()
    #expect(model.accountDescription == "Not signed in")
    #expect(model.canSignIn)

    var snapshot = MirrorSnapshot()
    snapshot.account = .signedIn(email: nil)
    await service.push(snapshot)
    #expect(await eventually { model.accountDescription == "Signed in" })
    #expect(!model.canSignIn)
  }

  @Test func addsRootWithDefaultNameAndRejectsDuplicates() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    var snapshot = MirrorSnapshot()
    snapshot.roots = [sampleRoot("Notes")]
    await service.push(snapshot)
    await model.start()

    await model.addRoot(URL(filePath: "/Users/me/Journal/", directoryHint: .isDirectory))
    await model.addRoot(URL(filePath: "/tmp/Notes"), displayName: "  ")
    await model.addRoot(URL(filePath: "/tmp/Other"), displayName: " Custom ")

    #expect(
      await service.calls == [
        .addRoot("/Users/me/Journal", "Journal"), .addRoot("/tmp/Other", "Custom"),
      ])
    #expect(model.errorMessage == nil)
  }

  @Test func rejectsDuplicateRoot() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    var snapshot = MirrorSnapshot()
    snapshot.roots = [sampleRoot("Notes")]
    await service.push(snapshot)
    await model.start()

    await model.addRoot(URL(filePath: "/tmp/Notes"))
    #expect(model.errorMessage == "/tmp/Notes is already being mirrored.")
    #expect(await service.calls.isEmpty)
  }

  @Test func rejectsDisplayNamesAnotherRootAlreadyUses() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    let notes = sampleRoot("Notes")
    let journal = sampleRoot("Journal")
    var snapshot = MirrorSnapshot()
    snapshot.roots = [notes, journal]
    await service.push(snapshot)
    await model.start()

    await model.addRoot(URL(filePath: "/tmp/Elsewhere"), displayName: " notes ")
    #expect(
      model.errorMessage == "Another folder is already named “notes”. Choose a different name.")
    await model.rename(journal.id, to: "NOTES")
    #expect(model.errorMessage?.hasPrefix("Another folder is already named") == true)
    #expect(await service.calls.isEmpty)

    // Changing only the case of its own name is fine, and clears the error.
    await model.rename(notes.id, to: "NOTES")
    var expected = notes.config
    expected.displayName = "NOTES"
    #expect(await service.calls == [.updateRoot(expected)])
    #expect(model.errorMessage == nil)
  }

  @Test func editsPatterns() async throws {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    let root = sampleRoot()
    var snapshot = MirrorSnapshot()
    snapshot.roots = [root]
    await service.push(snapshot)
    await model.start()

    #expect(SettingsViewModel.patternsText(PathFilter.defaultExclude) == ".trash/\n.obsidian/")
    await model.updatePatterns(for: root.id, include: "\n", exclude: "")
    #expect(model.errorMessage?.contains("include pattern") == true)

    await model.updatePatterns(
      for: root.id, include: "**/*.md\n notes/*.txt \n", exclude: "archive/")
    var expected = root.config
    expected.filter = PathFilter(
      include: [GlobPattern("**/*.md"), GlobPattern("notes/*.txt")],
      exclude: [GlobPattern("archive/")])
    #expect(await service.calls == [.updateRoot(expected)])
    #expect(model.errorMessage == nil)
  }

  @Test func surfacesServiceErrors() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    await model.start()
    await service.fail(with: CocoaError(.fileReadCorruptFile))
    await model.importClientFile(URL(filePath: "/tmp/client.json"))
    #expect(model.errorMessage != nil)
  }

  @Test func forwardsTheDriveFolderName() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    await model.setDriveFolderName("Claude Notes")
    #expect(await service.calls == [.setDriveFolderName("Claude Notes")])
  }

  @Test func togglesLaunchAtLogin() async {
    let model = SettingsViewModel(service: service, loginItem: loginItem)
    model.setLaunchAtLogin(true)
    #expect(model.launchAtLogin)

    loginItem.error = CocoaError(.featureUnsupported)
    model.setLaunchAtLogin(false)
    #expect(model.launchAtLogin)
    #expect(model.errorMessage?.hasPrefix("Couldn't change launch at login") == true)
  }
}
