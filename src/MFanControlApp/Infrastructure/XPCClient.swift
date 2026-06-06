import Foundation
import MFanControlShared

final class XPCClient {
    func send(_ command: ControlCommand) {
        // TODO: replace with real XPC client to helper
        print("XPC send: action=\(command.action.rawValue), rpm=\(command.targetRPM)")
    }
}
