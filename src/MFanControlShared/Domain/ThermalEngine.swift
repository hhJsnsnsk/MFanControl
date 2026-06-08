import Foundation

public final class ThermalEngine {
    public init() {}

    public func buildPolicy(
        from profile: ThermalPolicy.Mode,
        score: ThermalScore,
        appBoostActive: Bool,
        currentRPM: Int,
        constraints: (min: Int, max: Int, rampStep: Int),
        onBattery: Bool = false,
        externalDisplay: Bool = false,
        customCurve: [ThermalPolicy.CurvePoint]? = nil,
        upgradeConservativeMode: Bool = false
    ) -> ControlCommand {
        let policy = ThermalPolicy.defaults(for: profile)
        let curve = customCurve ?? policy.customCurve
        var target = targetRPM(for: policy, curve: curve, score: score.clampedValue)

        if appBoostActive {
            target += upgradeConservativeMode ? 90 : 180
        }
        target += Int(score.clampedValue * Double(policy.thermalScoreBias) / 100.0)

        if externalDisplay {
            target += upgradeConservativeMode ? 60 : 180
        }
        if onBattery {
            target -= 80
        }
        if upgradeConservativeMode {
            target = Int(Double(target) * 0.92)
        }

        let policyMax = profile == .customCurve ? constraints.max : min(constraints.max, policy.targetMaxRPM)
        let clampedTarget = min(policyMax, max(constraints.min, target))
        let delta = clampedTarget - currentRPM
        let step = min(abs(delta), constraints.rampStep)
        let applied = currentRPM + (delta >= 0 ? step : -step)
        let safeTarget = max(constraints.min, min(policyMax, applied))
        let safetyReason = score.band == .safety ? "safety-zone" : "\(score.band)"

        return ControlCommand(
            action: .setProfile,
            targetRPM: safeTarget,
            minRPM: constraints.min,
            maxRPM: constraints.max,
            rampStep: constraints.rampStep,
            reason: "profile=\(profile.rawValue);band=\(safetyReason);conservative=\(upgradeConservativeMode)"
        )
    }

    private func targetRPM(for policy: ThermalPolicy, curve: [ThermalPolicy.CurvePoint], score: Double) -> Int {
        let sortedCurve = curve.sorted { $0.score < $1.score }
        if sortedCurve.isEmpty { return policy.targetRPM }
        if score <= Double(sortedCurve.first?.score ?? 0) { return sortedCurve.first?.rpm ?? policy.targetRPM }
        if score >= Double(sortedCurve.last?.score ?? 100) { return sortedCurve.last?.rpm ?? policy.targetRPM }

        for i in 0..<(sortedCurve.count - 1) {
            let left = sortedCurve[i]
            let right = sortedCurve[i + 1]
            if Double(left.score) <= score && score <= Double(right.score) {
                let span = right.score - left.score
                guard span != 0 else { return left.rpm }
                let t = (score - Double(left.score)) / Double(span)
                let rpm = Double(left.rpm) + t * Double(right.rpm - left.rpm)
                return Int(rpm.rounded())
            }
        }
        return policy.targetRPM
    }
}
