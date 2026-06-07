import Foundation

public struct ThermalScoringEngine {
    public enum Metric {
        case cpu
        case gpu
        case soc
        case ssd
        case power
    }

    public var weights: ThermalWeights
    public var sustainedWindowSec: Double
    public var sampleIntervalSec: Double
    public var smoothingFactor: Double

    public init(
        weights: ThermalWeights = ThermalWeights(),
        sustainedWindowSec: Double = 15,
        sampleIntervalSec: Double = 2,
        smoothingFactor: Double = 0.3
    ) {
        self.weights = weights
        self.sustainedWindowSec = sustainedWindowSec
        self.sampleIntervalSec = sampleIntervalSec
        self.smoothingFactor = min(1, max(0, smoothingFactor))
    }

    public func normalizedTempScore(_ temp: Double?, minTemperature: Double, maxTemperature: Double) -> Double {
        guard let value = temp else { return 0 }
        if maxTemperature <= minTemperature { return 0 }
        return Swift.min(100.0, Swift.max(0.0, (value - minTemperature) / (maxTemperature - minTemperature) * 100.0))
    }

    public func estimateLoadBoost(_ sample: SensorSample, previous: Double?) -> Double {
        guard let sustained = sample.sustainedLoadSec else { return 0 }
        let ratio = sustained / max(1, sustainedWindowSec)
        let raw = min(1, max(0, ratio))
        return raw * 20
    }

    public func compute(_ sample: SensorSample, previousScore: Double? = nil) -> ThermalScore {
        let weighted = [
            ("cpu", normalizedTempScore(sample.cpuPcoreTempC ?? sample.cpuEcoreTempC, minTemperature: 40, maxTemperature: 105), weights.cpu),
            ("gpu", normalizedTempScore(sample.gpuTempC, minTemperature: 40, maxTemperature: 105), weights.gpu),
            ("soc", normalizedTempScore(sample.socTempC, minTemperature: 38, maxTemperature: 105), weights.soc),
            ("ssd", normalizedTempScore(sample.ssdTempC, minTemperature: 30, maxTemperature: 95), weights.ssd),
            ("power", normalizedTempScore(sample.powerWatts, minTemperature: 2, maxTemperature: 80), weights.power)
        ]

        let weightSum = weighted.reduce(0.0) { $0 + $1.2 }
        let base = weightSum == 0
            ? 0
            : weighted.reduce(0.0) { $0 + $1.1 * $1.2 } / weightSum

        let sustained = sample.sustainedLoadSec ?? 0
        let persistence = min(1.0, sustained / max(1, sustainedWindowSec))
        let rawScore = min(100.0, max(0.0, base + estimateLoadBoost(sample, previous: previousScore)))
        let smoothed: Double
        if let prev = previousScore {
            let baseline = prev * (1 - smoothingFactor) + rawScore * smoothingFactor
            if rawScore > prev {
                let maxUpStep = 5.0 + 23.0 * persistence
                smoothed = min(baseline, prev + maxUpStep)
            } else {
                smoothed = baseline
            }
        } else {
            smoothed = rawScore
        }

        let score = ThermalScore(
            value: min(100, max(0, smoothed)),
            quietBand: 0...30,
            warningBand: 31...60,
            aggressiveBand: 61...80,
            safetyBand: 81...100
        )
        return score
    }
}
