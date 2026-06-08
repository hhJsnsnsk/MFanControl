import Foundation

public struct ThermalPolicy: Codable, Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case quiet
        case balanced
        case performance
        case customCurve
    }

    public struct CurvePoint: Codable, Sendable {
        public var score: Int
        public var rpm: Int

        public init(score: Int, rpm: Int) {
            self.score = score
            self.rpm = rpm
        }
    }

    public var name: String
    public var mode: Mode
    public var targetMinRPM: Int
    public var targetMaxRPM: Int
    public var targetRPM: Int
    public var thermalScoreBias: Int
    public var customCurve: [CurvePoint]

    public init(
        name: String,
        mode: Mode,
        targetMinRPM: Int,
        targetMaxRPM: Int,
        targetRPM: Int,
        thermalScoreBias: Int = 0,
        customCurve: [CurvePoint] = []
    ) {
        self.name = name
        self.mode = mode
        self.targetMinRPM = targetMinRPM
        self.targetMaxRPM = targetMaxRPM
        self.targetRPM = targetRPM
        self.thermalScoreBias = thermalScoreBias
        self.customCurve = customCurve
    }

    public static func defaults(for mode: Mode) -> ThermalPolicy {
        switch mode {
        case .quiet:
            return .init(name: "quiet", mode: .quiet, targetMinRPM: 1200, targetMaxRPM: 3200, targetRPM: 1400, thermalScoreBias: 0, customCurve: [
                .init(score: 0, rpm: 1200),
                .init(score: 50, rpm: 1200),
                .init(score: 65, rpm: 1800),
                .init(score: 80, rpm: 2500),
                .init(score: 100, rpm: 3200)
            ])
        case .balanced:
            return .init(name: "balanced", mode: .balanced, targetMinRPM: 1400, targetMaxRPM: 4300, targetRPM: 1800, thermalScoreBias: 0, customCurve: [
                .init(score: 0, rpm: 1400),
                .init(score: 45, rpm: 1400),
                .init(score: 60, rpm: 2200),
                .init(score: 75, rpm: 3200),
                .init(score: 100, rpm: 4300)
            ])
        case .performance:
            return .init(name: "performance", mode: .performance, targetMinRPM: 1600, targetMaxRPM: 6200, targetRPM: 2400, thermalScoreBias: 10, customCurve: [
                .init(score: 0, rpm: 1600),
                .init(score: 40, rpm: 1600),
                .init(score: 60, rpm: 2800),
                .init(score: 80, rpm: 4800),
                .init(score: 100, rpm: 6200)
            ])
        case .customCurve:
            return .init(name: "customCurve", mode: .customCurve, targetMinRPM: 1300, targetMaxRPM: 5000, targetRPM: 2000, thermalScoreBias: 0, customCurve: [
                .init(score: 50, rpm: 1200),
                .init(score: 60, rpm: 1800),
                .init(score: 70, rpm: 2600),
                .init(score: 80, rpm: 3800),
                .init(score: 90, rpm: 5000)
            ])
        }
    }
}

public struct ThermalProfile: Codable, Sendable {
    public var identifier: String
    public var policy: ThermalPolicy
    public var createdAt: Date

    public init(identifier: String, policy: ThermalPolicy, createdAt: Date = Date()) {
        self.identifier = identifier
        self.policy = policy
        self.createdAt = createdAt
    }
}
