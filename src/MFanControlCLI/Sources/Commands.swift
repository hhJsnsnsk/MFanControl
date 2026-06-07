import Foundation
import MFanControlShared

enum CLICommand: String, CaseIterable {
    case status
    case history
    case events
    case setMode = "set-mode"
    case forceDefault = "force-default"
    case whitelist
    case exportConfig = "export-config"
    case importConfig = "import-config"
    case setCustomCurve = "set-custom-curve"
    case setRPM = "set-rpm"
    case uninstall
}

struct CLIUsage {
    static let text = """
MFanControlCLI:
  status
  history [n]
  events [n]
  set-mode <quiet|balanced|performance|customCurve>
  set-custom-curve <score:rpm score:rpm ...>
  set-rpm <rpm>
  whitelist list|add <name...>|remove <name...>
  force-default
  export-config <file>
  import-config <file>
  uninstall
"""
}
