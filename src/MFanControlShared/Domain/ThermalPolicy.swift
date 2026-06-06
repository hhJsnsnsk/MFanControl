import Foundation

public struct ThermalPolicy: Codable, Sendable {
    public enum Mode: String, Codable {
        case quiet
        case balanced
        case performance
        case customCurve
    }

    public var name: String
    public var mode: Mode
    public var targetMinRPM: Int
    public var targetMaxRPM: Int
    public var targetRPM: Int
    public var thermalScoreBias: Int

    public init(
        name: String,
        mode: Mode,
        targetMinRPM: Int,
        targetMaxRPM: Int,
        targetRPM: Int,
        thermalScoreBias: Int = 0
    ) {
        self.name = name
        self.mode = mode
        self.targetMinRPM = targetMinRPM
        self.targetMaxRPM = targetMaxRPM
        self.targetRPM = targetRPM
        self.thermalScoreBias = thermalScoreBias
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
