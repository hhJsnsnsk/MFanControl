import Foundation
import MFanControlShared

protocol FanControlService {
    func currentState() -> ControlState
    func apply(_ command: ControlCommand) -> Bool
    func restoreToAppleDefault() -> Bool
}
