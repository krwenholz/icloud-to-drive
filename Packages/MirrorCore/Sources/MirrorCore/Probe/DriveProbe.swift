import Foundation

public struct ProbeCheck: Equatable, Sendable {
  public var name: String
  public var passed: Bool
  public var detail: String
}

public struct ProbeReport: Equatable, Sendable {
  public var checks: [ProbeCheck] = []
  /// `.replace` when in-place updates don't keep the Doc intact, `.inPlace` when they do.
  public var recommendedStrategy: UpdateStrategy?
  public var comparison: (original: String, exported: String)?
  public var comparisonName: String?

  public var passed: Bool { !checks.isEmpty && checks.allSatisfy(\.passed) }

  public static func == (lhs: ProbeReport, rhs: ProbeReport) -> Bool {
    lhs.checks == rhs.checks && lhs.recommendedStrategy == rhs.recommendedStrategy
      && lhs.comparison?.original == rhs.comparison?.original
      && lhs.comparison?.exported == rhs.comparison?.exported
      && lhs.comparisonName == rhs.comparisonName
  }
}

/// A live check of the Drive behavior the engine depends on, in a throwaway folder.
public struct DriveProbe: Sendable {
  private let drive: any ProbeDriveClient
  private let corpus: [ProbeFixture]
  private let now: @Sendable () -> Date
  private let probeID: UUID

  public init(
    drive: any ProbeDriveClient, corpus: [ProbeFixture] = ProbeCorpus.fixtures,
    now: @escaping @Sendable () -> Date = { Date() }, probeID: UUID = UUID()
  ) {
    self.drive = drive
    self.corpus = corpus
    self.now = now
    self.probeID = probeID
  }

  public static func folderName(at date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    // No colons: they look odd in Drive's UI.
    formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss'Z'"
    return "Drive Mirror Probe \(formatter.string(from: date))"
  }

  public func run() async -> ProbeReport {
    var report = ProbeReport()
    func record(_ name: String, _ passed: Bool, _ detail: String) {
      report.checks.append(ProbeCheck(name: name, passed: passed, detail: detail))
    }

    do {
      let email = try await drive.userEmail()
      record(
        "About returns email", email != nil,
        email ?? "no email; the app will show \"Signed in\" without one")
    } catch {
      record("About returns email", false, "\(error)")
    }

    let folder: DriveFile
    do {
      folder = try await drive.createFolder(
        name: Self.folderName(at: now()), parentID: nil,
        description: "Temporary probe folder from mirrorctl. Safe to delete.",
        appProperties: [
          AppPropertyKey.root: probeID.uuidString,
          AppPropertyKey.kind: DriveItemKind.folder.rawValue,
        ])
      record("Create probe folder", true, folder.name)
    } catch {
      record("Create probe folder", false, "\(error)")
      return report
    }

    await exercise(folder: folder, report: &report)

    // Always clean up, even after failures. Trashing the folder takes its Docs with it.
    do {
      try await drive.trashFile(id: folder.id)
      record("Trash probe folder", true, folder.id)
    } catch {
      record("Trash probe folder", false, "\(error); trash '\(folder.name)' by hand")
    }
    return report
  }

  private func exercise(folder: DriveFile, report: inout ProbeReport) async {
    func record(_ name: String, _ passed: Bool, _ detail: String) {
      report.checks.append(ProbeCheck(name: name, passed: passed, detail: detail))
    }

    var uploaded: [(fixture: ProbeFixture, file: DriveFile)] = []
    for fixture in corpus {
      let content = PreparedContent(markdown: Data(fixture.markdown.utf8))
      do {
        let file = try await drive.createFile(
          markdown: content.data, name: fixture.name, parentID: folder.id,
          description: "Drive Mirror probe / \(fixture.name).md",
          appProperties: properties(hash: content.hash), convert: true)
        let isDoc = file.mimeType == DriveFile.docMimeType
        record("Upload '\(fixture.name)'", isDoc, isDoc ? file.id : "type was \(file.mimeType)")
        uploaded.append((fixture, file))
      } catch {
        record("Upload '\(fixture.name)'", false, "\(error)")
      }
    }

    // Update a fixture other than the comparison one, so the export below shows the original.
    if let target = uploaded.last {
      await updateInPlace(target.fixture, target.file, report: &report)
    }

    do {
      let found = Set(
        try await drive.listFiles(appProperty: AppPropertyKey.root, value: probeID.uuidString).map(
          \.id))
      let missing = uploaded.filter { !found.contains($0.file.id) }.map(\.fixture.name)
      record(
        "List by appProperties", missing.isEmpty && !uploaded.isEmpty,
        missing.isEmpty
          ? "found \(uploaded.count) uploaded files" : "missing: \(missing.joined(separator: ", "))"
      )
    } catch {
      record("List by appProperties", false, "\(error)")
    }

    if let sample = uploaded.first(where: { $0.fixture.name == ProbeCorpus.comparisonFixtureName })
      ?? uploaded.first
    {
      do {
        let exported = try await drive.exportMarkdown(id: sample.file.id)
        record("Export as Markdown", !exported.isEmpty, "\(exported.count) characters")
        report.comparisonName = sample.fixture.name
        report.comparison = (sample.fixture.markdown, exported)
      } catch {
        record("Export as Markdown", false, "\(error)")
      }
    }
  }

  static let updateMarker = "Updated by the probe."

  /// In-place updates are unconfirmed for Markdown conversion, so check all three things the
  /// engine relies on: same file ID, still a Google Doc, and the new text actually landed.
  private func updateInPlace(
    _ fixture: ProbeFixture, _ original: DriveFile, report: inout ProbeReport
  ) async {
    let content = PreparedContent(
      markdown: Data((fixture.markdown + "\n\n\(Self.updateMarker)\n").utf8))
    var sameID = false
    var sameType = false
    var contentChanged = false
    var detail = ""
    var contentDetail = ""
    do {
      _ = try await drive.updateFile(
        id: original.id, markdown: content.data, description: original.description ?? "",
        appProperties: properties(hash: content.hash))
      let current = try await drive.getFile(id: original.id)
      sameID = current.id == original.id
      sameType = current.mimeType == DriveFile.docMimeType
      detail = "\(current.id), \(current.mimeType)"
      let exported = try await drive.exportMarkdown(id: original.id)
      contentChanged = exported.contains(Self.updateMarker)
      contentDetail = contentChanged ? "new text found in export" : "export lacks the new text"
    } catch {
      detail = "\(error)"
      contentDetail = detail
    }
    report.checks.append(
      ProbeCheck(name: "In-place update keeps file ID", passed: sameID, detail: detail))
    report.checks.append(
      ProbeCheck(name: "In-place update keeps Google Doc type", passed: sameType, detail: detail))
    report.checks.append(
      ProbeCheck(
        name: "In-place update changes content", passed: contentChanged, detail: contentDetail))
    report.recommendedStrategy = sameID && sameType && contentChanged ? .inPlace : .replace
  }

  private func properties(hash: String) -> [String: String] {
    [
      AppPropertyKey.root: probeID.uuidString,
      AppPropertyKey.pathHash: Hashing.sha256Hex(probeID.uuidString),
      AppPropertyKey.contentHash: hash,
      AppPropertyKey.kind: DriveItemKind.doc.rawValue,
    ]
  }
}

extension ProbeReport {
  /// The PASS/FAIL table, the strategy recommendation, and the original-vs-exported text.
  public func render() -> [String] {
    var lines = [
      TextTable.render(
        headers: ["Result", "Check", "Detail"],
        rows: checks.map { [$0.passed ? "PASS" : "FAIL", $0.name, $0.detail] })
    ]
    if let recommendedStrategy {
      lines.append("")
      lines.append(
        recommendedStrategy == .inPlace
          ? "Recommendation: .inPlace works; keep it as the update strategy."
          : "Recommendation: .replace should be the update strategy (in-place updates failed).")
    }
    if let comparison {
      lines.append("")
      lines.append("===== Original Markdown: \(comparisonName ?? "") =====")
      lines.append(comparison.original)
      lines.append("===== Exported from the Google Doc (text/markdown) =====")
      lines.append(comparison.exported)
      lines.append("===== End of comparison =====")
    }
    lines.append("")
    lines.append(passed ? "All checks passed." : "Some checks FAILED.")
    return lines
  }
}
