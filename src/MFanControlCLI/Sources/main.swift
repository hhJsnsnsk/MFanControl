import Foundation
import MFanControlShared

enum CLICommand: String {
    case status
    case history
    case setMode
    case forceDefault
}

struct CLI {
    static func run() {
        let args = CommandLine.arguments
        guard args.count > 1, let cmd = CLICommand(rawValue: args[1]) else {
            printUsage()
            return
        }

        switch cmd {
        case .status:
            print("status: smart control placeholder")
        case .history:
            print("history: placeholder")
        case .setMode:
            print("set-mode placeholder")
        case .forceDefault:
            print("force-default placeholder")
        }
    }

    static func printUsage() {
        print("MFanControlCLI: status | history | setMode | forceDefault")
    }
}

CLI.run()
