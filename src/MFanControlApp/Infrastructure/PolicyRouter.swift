import Foundation
import MFanControlShared

final class PolicyRouter {
    private let engine = ThermalEngine()
    private let xpc = XPCClient()

    func applyProfile(_ profile: ThermalPolicy.Mode, score: ThermalScore, appBoost: Bool) {
        let cmd = engine.buildPolicy(from: profile, score: score, appBoostActive: appBoost)
        xpc.send(cmd)
    }
}
