import CaptiveKit
import Foundation

let code = await CLI(arguments: Array(CommandLine.arguments.dropFirst()), paths: .standard()).run()
exit(code)
