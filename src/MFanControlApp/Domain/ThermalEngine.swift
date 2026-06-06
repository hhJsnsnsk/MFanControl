import Foundation
import MFanControlShared

final class ThermalEngine {
    func buildPolicy(
        from profile: ThermalPolicy.Mode,
        score: ThermalScore,
        appBoostActive: Bool
    ) -> ControlCommand {
        let baseTarget = switch profile {
        case .quiet:
            1300
        case .balanced:
            1700
        case .performance:
            2400
        case .customCurve:
            2000
        }

        let boost = appBoostActive ? 200 : 0
        let rampStep = 300
        let target = min(baseTarget + Int(score.value) + boost, 6000)

        return ControlCommand(
            action: .setProfile,
            targetRPM: target,
            minRPM: baseTarget,
            maxRPM: 6000,
            rampStep: rampStep,
            reason: "thermal engine placeholder"
        )
    }
}
