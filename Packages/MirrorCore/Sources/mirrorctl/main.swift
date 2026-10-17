import Foundation
import MirrorCore

let code = await CLIRunner(environment: .live()).run(Array(CommandLine.arguments.dropFirst()))
exit(code)
