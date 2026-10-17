import Testing

@testable import MirrorCore

struct CLIParserTests {
  @Test func parsesSimpleCommands() throws {
    #expect(try CLIParser.parse(["auth"]) == .auth)
    #expect(try CLIParser.parse(["probe"]) == .probe)
    #expect(try CLIParser.parse(["help"]) == .help)
    #expect(try CLIParser.parse(["--help"]) == .help)
  }

  @Test func syncTakesAPathAndDryRunInAnyPosition() throws {
    #expect(try CLIParser.parse(["sync", "/a"]) == .sync(path: "/a", dryRun: false))
    #expect(try CLIParser.parse(["sync", "/a", "--dry-run"]) == .sync(path: "/a", dryRun: true))
    #expect(try CLIParser.parse(["sync", "--dry-run", "/a"]) == .sync(path: "/a", dryRun: true))
  }

  @Test func syncWithoutPathFails() {
    #expect(throws: CLIParseError.missingPath(command: "sync")) {
      try CLIParser.parse(["sync", "--dry-run"])
    }
    #expect(throws: CLIParseError.missingPath(command: "sync")) { try CLIParser.parse(["sync"]) }
  }

  @Test func rebuildStatePathIsOptional() throws {
    #expect(try CLIParser.parse(["rebuild-state"]) == .rebuildState(path: nil))
    #expect(try CLIParser.parse(["rebuild-state", "/a"]) == .rebuildState(path: "/a"))
  }

  @Test func rejectsMisuse() {
    #expect(throws: CLIParseError.noCommand) { try CLIParser.parse([]) }
    #expect(throws: CLIParseError.unknownCommand("frobnicate")) {
      try CLIParser.parse(["frobnicate"])
    }
    #expect(throws: CLIParseError.unexpectedArgument(command: "auth", argument: "x")) {
      try CLIParser.parse(["auth", "x"])
    }
    #expect(throws: CLIParseError.unexpectedArgument(command: "sync", argument: "--wat")) {
      try CLIParser.parse(["sync", "/a", "--wat"])
    }
    #expect(throws: CLIParseError.unexpectedArgument(command: "sync", argument: "/b")) {
      try CLIParser.parse(["sync", "/a", "/b"])
    }
  }

  @Test func usageErrorsExitTwoAndHelpExitsZero() async throws {
    let harness = try CLIHarness()
    defer { harness.cleanUp() }
    let runner = harness.runner()
    #expect(await runner.run([]) == 2)
    #expect(await runner.run(["nope"]) == 2)
    #expect(await runner.run(["sync"]) == 2)
    #expect(await runner.run(["help"]) == 0)
    #expect(harness.out.text.contains("Usage: mirrorctl"))
  }
}
