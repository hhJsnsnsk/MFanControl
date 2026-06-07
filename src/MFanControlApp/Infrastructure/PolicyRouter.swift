import Foundation
import MFanControlShared

final class PolicyRouter {
    private let engine = ThermalEngine()
    private let xpc: XPCClient

    init(xpc: XPCClient = XPCClient()) {
        self.xpc = xpc
    }

    func applyProfile(_ profile: ThermalPolicy.Mode, score: ThermalScore, appBoost: Bool, currentRPM: Int, hasFans: Bool = true) -> ControlCommand {
        let constraints = (min: hasFans ? 1200 : 0, max: hasFans ? 6200 : 0, rampStep: 300)
        let cmd = engine.buildPolicy(from: profile, score: score, appBoostActive: appBoost, currentRPM: currentRPM, constraints: constraints)
        _ = xpc.apply(cmd)
        return cmd
    }

    func executeProfile(_ profile: ThermalPolicy.Mode, score: ThermalScore, appBoost: Bool, currentRPM: Int, hasFans: Bool = true) -> FanControlResult {
        let cmd = applyProfile(profile, score: score, appBoost: appBoost, currentRPM: currentRPM, hasFans: hasFans)
        return xpc.apply(cmd)
    }
}
