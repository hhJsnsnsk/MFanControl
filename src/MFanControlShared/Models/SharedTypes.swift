import Foundation

public struct FanCapability: Codable, Sendable {
    public var fanCount: Int
    public var minRPM: Int
    public var maxRPM: Int
    public var modelIdentifier: String
    public var controllable: Bool

    public init(
        fanCount: Int,
        minRPM: Int,
        maxRPM: Int,
        modelIdentifier: String,
        controllable: Bool
    ) {
        self.fanCount = fanCount
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.modelIdentifier = modelIdentifier
        self.controllable = controllable
    }
}

public struct HardwareProfile: Codable, Sendable {
    public var chip: String
    public var deviceModel: String
    public var isAppleSilicon: Bool
    public var hasFans: Bool
    public var fans: [FanCapability]

    public init(
        chip: String,
        deviceModel: String,
        isAppleSilicon: Bool,
        hasFans: Bool,
        fans: [FanCapability]
    ) {
        self.chip = chip
        self.deviceModel = deviceModel
        self.isAppleSilicon = isAppleSilicon
        self.hasFans = hasFans
        self.fans = fans
    }
}

public struct ControlCommand: Codable, Sendable {
    public enum Action: String, Codable {
        case setProfile
        case applyPolicy
        case restoreDefault
        case refreshState
    }

    public var action: Action
    public var targetRPM: Int
    public var minRPM: Int?
    public var maxRPM: Int?
    public var rampStep: Int?
    public var reason: String?

    public init(
        action: Action,
        targetRPM: Int,
        minRPM: Int? = nil,
        maxRPM: Int? = nil,
        rampStep: Int? = nil,
        reason: String? = nil
    ) {
        self.action = action
        self.targetRPM = targetRPM
        self.minRPM = minRPM
        self.maxRPM = maxRPM
        self.rampStep = rampStep
        self.reason = reason
    }
}
