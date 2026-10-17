/// A parsed `mirrorctl` invocation.
public enum CLICommand: Equatable, Sendable {
  case help
  case auth
  case probe
  case sync(path: String, dryRun: Bool)
  case rebuildState(path: String?)
}

public enum CLIParseError: Error, Equatable, CustomStringConvertible, Sendable {
  case noCommand
  case unknownCommand(String)
  case missingPath(command: String)
  case unexpectedArgument(command: String, argument: String)

  public var description: String {
    switch self {
    case .noCommand: "No command given."
    case .unknownCommand(let name): "Unknown command '\(name)'."
    case .missingPath(let command): "'\(command)' needs a folder path."
    case .unexpectedArgument(let command, let argument):
      "'\(command)' doesn't take '\(argument)'."
    }
  }
}

public enum CLIParser {
  public static let usage = """
    Usage: mirrorctl <command>

    Commands:
      auth                         Sign in to Google (shared with the Drive Mirror app)
      probe                        Check Drive behavior live and print a PASS/FAIL table
      sync <path> [--dry-run]      Reconcile a folder; --dry-run only prints the plan
      rebuild-state [<path>]       Rebuild local state from Drive, for one folder or every root
      help                         Show this text

    A <path> that matches a root in the app's config uses that root and the app's state.
    Any other folder is synced as a temporary root with its own state file.
    """

  public static func parse(_ arguments: [String]) throws(CLIParseError) -> CLICommand {
    guard let name = arguments.first else { throw .noCommand }
    let rest = Array(arguments.dropFirst())
    switch name {
    case "help", "--help", "-h":
      return .help
    case "auth":
      try requireNone(rest, command: name)
      return .auth
    case "probe":
      try requireNone(rest, command: name)
      return .probe
    case "sync":
      var path: String?
      var dryRun = false
      for argument in rest {
        if argument == "--dry-run" {
          dryRun = true
        } else if argument.hasPrefix("--") {
          throw .unexpectedArgument(command: name, argument: argument)
        } else if path == nil {
          path = argument
        } else {
          throw .unexpectedArgument(command: name, argument: argument)
        }
      }
      guard let path else { throw .missingPath(command: name) }
      return .sync(path: path, dryRun: dryRun)
    case "rebuild-state":
      if let extra = rest.dropFirst().first {
        throw .unexpectedArgument(command: name, argument: extra)
      }
      if let first = rest.first, first.hasPrefix("--") {
        throw .unexpectedArgument(command: name, argument: first)
      }
      return .rebuildState(path: rest.first)
    default:
      throw .unknownCommand(name)
    }
  }

  private static func requireNone(_ rest: [String], command: String) throws(CLIParseError) {
    if let extra = rest.first { throw .unexpectedArgument(command: command, argument: extra) }
  }
}
