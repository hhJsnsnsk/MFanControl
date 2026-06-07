import Foundation

public enum ControlState: String, Codable, CaseIterable, Sendable {
    case idle
    case discovering
    case smartControl
    case safetyFallback
    case manualDefault
}

public enum ControlSource: String, Codable, Sendable {
    case appleDefault
    case appAuto
    case userManual
    case safetyMode
}

public enum FanControlFailure: String, Codable, Sendable {
    case none
    case notAvailable
    case invalidCommand
    case hardwareUnreachable
    case outOfRange
}

public struct RawTemperatureSensorReading: Codable, Sendable {
    public var name: String
    public var tempC: Double

    public init(name: String, tempC: Double) {
        self.name = name
        self.tempC = tempC
    }
}

public struct SensorSample: Codable, Sendable {
    public var timestamp: Date
    public var cpuPcoreTempC: Double?
    public var cpuEcoreTempC: Double?
    public var gpuTempC: Double?
    public var socTempC: Double?
    public var ssdTempC: Double?
    public var batteryTempC: Double?
    public var memoryTempC: Double?
    public var powerWatts: Double?
    public var sustainedLoadSec: Double?
    public var rawTemperatureSensors: [RawTemperatureSensorReading]

    public init(
        timestamp: Date,
        cpuPcoreTempC: Double? = nil,
        cpuEcoreTempC: Double? = nil,
        gpuTempC: Double? = nil,
        socTempC: Double? = nil,
        ssdTempC: Double? = nil,
        batteryTempC: Double? = nil,
        memoryTempC: Double? = nil,
        powerWatts: Double? = nil,
        sustainedLoadSec: Double? = nil,
        rawTemperatureSensors: [RawTemperatureSensorReading] = []
    ) {
        self.timestamp = timestamp
        self.cpuPcoreTempC = cpuPcoreTempC
        self.cpuEcoreTempC = cpuEcoreTempC
        self.gpuTempC = gpuTempC
        self.socTempC = socTempC
        self.ssdTempC = ssdTempC
        self.batteryTempC = batteryTempC
        self.memoryTempC = memoryTempC
        self.powerWatts = powerWatts
        self.sustainedLoadSec = sustainedLoadSec
        self.rawTemperatureSensors = rawTemperatureSensors
    }
}

public struct ThermalSampleBatch: Codable, Sendable {
    public var samples: [SensorSample]
    public var source: String
    public var reason: String

    public init(samples: [SensorSample], source: String = "unknown", reason: String = "sample") {
        self.samples = samples
        self.source = source
        self.reason = reason
    }
}

public struct SensorAvailability: Codable, Sendable {
    public var isAvailable: Bool
    public var confidence: Double

    public init(isAvailable: Bool, confidence: Double = 1.0) {
        self.isAvailable = isAvailable
        self.confidence = max(0, min(1, confidence))
    }
}

public enum ThermalBand: String, Codable, Sendable {
    case quiet
    case warning
    case aggressive
    case safety
}

public struct ThermalScore: Codable, Sendable {
    public var value: Double
    public var quietBand: ClosedRange<Double>
    public var warningBand: ClosedRange<Double>
    public var aggressiveBand: ClosedRange<Double>
    public var safetyBand: ClosedRange<Double>
    public var updatedAt: Date

    public init(
        value: Double,
        quietBand: ClosedRange<Double> = 0...30,
        warningBand: ClosedRange<Double> = 31...60,
        aggressiveBand: ClosedRange<Double> = 61...80,
        safetyBand: ClosedRange<Double> = 81...100,
        updatedAt: Date = Date()
    ) {
        self.value = value
        self.quietBand = quietBand
        self.warningBand = warningBand
        self.aggressiveBand = aggressiveBand
        self.safetyBand = safetyBand
        self.updatedAt = updatedAt
    }

    public var band: ThermalBand {
        switch value {
        case quietBand:
            return .quiet
        case warningBand:
            return .warning
        case aggressiveBand:
            return .aggressive
        default:
            return .safety
        }
    }

    public var clampedValue: Double {
        min(100, max(0, value))
    }
}

public struct WeightedComponent: Codable, Sendable {
    public var name: String
    public var weight: Double
    public var enabled: Bool

    public init(name: String, weight: Double, enabled: Bool = true) {
        self.name = name
        self.weight = max(0, weight)
        self.enabled = enabled
    }
}

public struct ThermalWeights: Codable, Sendable {
    public var cpu: Double
    public var gpu: Double
    public var soc: Double
    public var ssd: Double
    public var power: Double

    public init(cpu: Double = 0.28, gpu: Double = 0.22, soc: Double = 0.24, ssd: Double = 0.10, power: Double = 0.16) {
        self.cpu = max(0, cpu)
        self.gpu = max(0, gpu)
        self.soc = max(0, soc)
        self.ssd = max(0, ssd)
        self.power = max(0, power)
        normalize()
    }

    mutating public func normalize() {
        let sum = cpu + gpu + soc + ssd + power
        if sum <= 0 { return }
        cpu /= sum
        gpu /= sum
        soc /= sum
        ssd /= sum
        power /= sum
    }
}

public struct SafetyThresholds: Codable, Sendable {
    public var thermalSafetyScore: Double
    public var sustainedSeconds: Double
    public var sampleIntervalSec: Double
    public var safetyReasonDebounceMinutes: Double

    public init(thermalSafetyScore: Double = 82, sustainedSeconds: Double = 15, sampleIntervalSec: Double = 2, safetyReasonDebounceMinutes: Double = 15) {
        self.thermalSafetyScore = thermalSafetyScore
        self.sustainedSeconds = sustainedSeconds
        self.sampleIntervalSec = sampleIntervalSec
        self.safetyReasonDebounceMinutes = safetyReasonDebounceMinutes
    }
}

public struct HistoryRetention: Codable, Sendable {
    public var rawMinutes: Int
    public var aggregateHours: Int

    public init(rawMinutes: Int = 1440, aggregateHours: Int = 720) {
        self.rawMinutes = max(1, rawMinutes)
        self.aggregateHours = max(1, aggregateHours)
    }

    private enum CodingKeys: String, CodingKey {
        case rawMinutes
        case aggregateHours
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let values = try container.decode([String: Int].self)

        let rawMinutes = values["rawMinutes"]
            ?? values["raw_minutes"]
            ?? 1440
        let aggregateHours = values["aggregateHours"]
            ?? values["aggregate_hours"]
            ?? values["aggHours"]
            ?? values["agg_hours"]
            ?? 720

        self.rawMinutes = max(1, rawMinutes)
        self.aggregateHours = max(1, aggregateHours)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rawMinutes, forKey: .rawMinutes)
        try container.encode(aggregateHours, forKey: .aggregateHours)
    }
}

public struct ThermalControlConfig: Codable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var profile: String
    public var weights: ThermalWeights
    public var historyRetention: HistoryRetention
    public var whiteList: [String]
    public var safetyThresholds: SafetyThresholds
    public var customCurve: [ThermalPolicy.CurvePoint]?
    public var upgradeConservativeMode: Bool

    public init(
        schemaVersion: Int = 1,
        profile: String = "balanced",
        weights: ThermalWeights = ThermalWeights(),
        historyRetention: HistoryRetention = HistoryRetention(),
        whiteList: [String] = [
            "Xcode",
            "Android Studio",
            "JetBrains IDEA",
            "Final Cut Pro",
            "DaVinci Resolve",
            "Ollama",
            "LM Studio",
            "Docker",
            "Blender"
        ],
        safetyThresholds: SafetyThresholds = SafetyThresholds(),
        customCurve: [ThermalPolicy.CurvePoint]? = nil,
        upgradeConservativeMode: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.profile = profile
        self.weights = weights
        self.historyRetention = historyRetention
        self.whiteList = whiteList
        self.safetyThresholds = safetyThresholds
        self.customCurve = customCurve
        self.upgradeConservativeMode = upgradeConservativeMode
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profile
        case weights
        case historyRetention
        case whiteList
        case safetyThresholds
        case customCurve
        case upgradeConservativeMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.profile = try container.decodeIfPresent(String.self, forKey: .profile) ?? "balanced"
        self.weights = try container.decodeIfPresent(ThermalWeights.self, forKey: .weights) ?? ThermalWeights()
        self.historyRetention = try container.decodeIfPresent(HistoryRetention.self, forKey: .historyRetention) ?? HistoryRetention()
        self.whiteList = try container.decodeIfPresent([String].self, forKey: .whiteList) ?? [
            "Xcode",
            "Android Studio",
            "JetBrains IDEA",
            "Final Cut Pro",
            "DaVinci Resolve",
            "Ollama",
            "LM Studio",
            "Docker",
            "Blender"
        ]
        self.safetyThresholds = try container.decodeIfPresent(SafetyThresholds.self, forKey: .safetyThresholds) ?? SafetyThresholds()
        self.customCurve = try container.decodeIfPresent([ThermalPolicy.CurvePoint].self, forKey: .customCurve)
        self.upgradeConservativeMode = try container.decodeIfPresent(Bool.self, forKey: .upgradeConservativeMode) ?? false
    }

    public func isValid() -> Bool {
        validationReport().isValid
    }

    public func validationReport() -> ThermalControlConfigValidationReport {
        guard schemaVersion == Self.currentSchemaVersion else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "unsupported-schema-version-\(schemaVersion); expected \(Self.currentSchemaVersion). \(migrationSuggestion(currentVersion: schemaVersion, targetVersion: Self.currentSchemaVersion))"
            )
        }
        guard !profile.isEmpty else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "empty-profile is not allowed. Choose one of: \(Self.allProfileNames())"
            )
        }
        guard ThermalPolicy.Mode(rawValue: profile) != nil else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "unsupported-profile '\(profile)'. Choose one of: \(Self.allProfileNames())"
            )
        }
        guard whiteList.count <= 200 else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "whiteList exceeds supported size"
            )
        }
        guard safetyThresholds.thermalSafetyScore >= 70 && safetyThresholds.thermalSafetyScore <= 100 else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "thermalSafetyScore must be between 70 and 100"
            )
        }
        guard historyRetention.rawMinutes > 0 && historyRetention.aggregateHours > 0 else {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "history retention must be positive"
            )
        }
        if let customCurve, !areCurvePointsValid(customCurve) {
            return ThermalControlConfigValidationReport(
                isValid: false,
                reason: "customCurve is invalid. Ensure unique score points (0-100) and positive rpm per point."
            )
        }
        return ThermalControlConfigValidationReport(isValid: true)
    }

    public func normalized() -> ThermalControlConfig {
        var normalized = self
        if SafetyThresholdsProfileNormalization.isInvalidThresholds(safetyThresholds) {
            normalized.safetyThresholds = .init()
        }
        if !validProfile(profile) {
            normalized.profile = "balanced"
        }
        normalized.historyRetention = HistoryRetention(rawMinutes: max(1, historyRetention.rawMinutes), aggregateHours: max(1, historyRetention.aggregateHours))
        normalized.whiteList = normalized.whiteList
            .map(ProcessIdentityMatcher.normalizedName)
            .deduplicatedByNormalizedIdentity()
        normalized.customCurve = normalized.customCurve?
            .sorted(by: { $0.score < $1.score })
            .filter { $0.score >= 0 && $0.score <= 100 && $0.rpm >= 0 }
            .deduplicatedByScore()
        return normalized
    }

    private static func allProfileNames() -> String {
        ThermalPolicy.Mode.allCases.map(\.rawValue).joined(separator: ", ")
    }

    private func migrationSuggestion(currentVersion: Int, targetVersion: Int) -> String {
        if currentVersion < targetVersion {
            return "This config looks older than this app version. Upgrade flow: export with current app version, import again, or use schema_version=\(targetVersion)."
        }
        if currentVersion > targetVersion {
            return "This config may be from a newer schema. Update app version or re-export from this device."
        }
        return "Schema version matches."
    }
}

public enum SafetyThresholdsProfileNormalization {
    public static func isInvalidThresholds(_ thresholds: SafetyThresholds) -> Bool {
        thresholds.thermalSafetyScore < 70 || thresholds.thermalSafetyScore > 100
            || thresholds.sustainedSeconds <= 0
            || thresholds.sampleIntervalSec <= 0
            || thresholds.safetyReasonDebounceMinutes < 0
    }
}

public enum ProcessIdentityMatcher {
    public static func normalizedName(_ rawName: String) -> String {
        let lowered = rawName
            .replacingOccurrences(of: ".app", with: "", options: .caseInsensitive)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let compact = lowered
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return compact
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func matches(processName: String, whiteListEntry rawCandidate: String) -> Bool {
        let process = normalizedName(processName)
        let candidate = normalizedName(rawCandidate)
        guard !process.isEmpty, !candidate.isEmpty else { return false }
        return process.contains(candidate) || candidate.contains(process)
    }
}

private func validProfile(_ profile: String) -> Bool {
    ThermalPolicy.Mode(rawValue: profile) != nil
}

private func areCurvePointsValid(_ points: [ThermalPolicy.CurvePoint]) -> Bool {
    guard points.count > 1 else { return false }
    if !points.allSatisfy({ $0.score >= 0 && $0.score <= 100 && $0.rpm > 0 }) {
        return false
    }
    let scores = points.map(\.score)
    return Set(scores).count == points.count
}

private extension Array where Element == ThermalPolicy.CurvePoint {
    func deduplicatedByScore() -> [ThermalPolicy.CurvePoint] {
        var seen = Set<Int>()
        return filter { seen.insert($0.score).inserted }
    }
}

public extension Array where Element == String {
    func deduplicatedByNormalizedIdentity() -> [String] {
        var seen: Set<String> = []
        return compactMap { value in
            let normalized = ProcessIdentityMatcher.normalizedName(value)
            guard !normalized.isEmpty else { return nil }
            if seen.insert(normalized).inserted {
                return normalized
            }
            return nil
        }
    }
}

public struct FanControlResult: Codable, Sendable {
    public var success: Bool
    public var reason: String
    public var failure: FanControlFailure
    public var state: ControlState
    public var source: ControlSource
    public var timestamp: Date

    public init(
        success: Bool,
        reason: String,
        failure: FanControlFailure = .none,
        state: ControlState,
        source: ControlSource,
        timestamp: Date = Date()
    ) {
        self.success = success
        self.reason = reason
        self.failure = failure
        self.state = state
        self.source = source
        self.timestamp = timestamp
    }
}

public struct FanControlSnapshot: Codable, Sendable {
    public var state: ControlState
    public var source: ControlSource
    public var hardwareProfile: HardwareProfile?
    public var activeProfile: String
    public var currentRPM: Int
    public var targetRPM: Int
    public var appBoostActive: Bool
    public var thermalScore: Double?
    public var powerSource: String
    public var throttleState: ThermalThrottleState
    public var sensorAvailability: [String: SensorChannelAvailability]
    public var reason: String
    public var timestamp: Date

    public init(
        state: ControlState,
        source: ControlSource,
        hardwareProfile: HardwareProfile?,
        activeProfile: String,
        currentRPM: Int,
        targetRPM: Int,
        appBoostActive: Bool,
        thermalScore: Double?,
        powerSource: String = "unknown",
        throttleState: ThermalThrottleState = ThermalThrottleState(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: ""),
        sensorAvailability: [String: SensorChannelAvailability] = [:],
        reason: String,
        timestamp: Date = Date()
    ) {
        self.state = state
        self.source = source
        self.hardwareProfile = hardwareProfile
        self.activeProfile = activeProfile
        self.currentRPM = currentRPM
        self.targetRPM = targetRPM
        self.appBoostActive = appBoostActive
        self.thermalScore = thermalScore
        self.powerSource = powerSource
        self.throttleState = throttleState
        self.sensorAvailability = sensorAvailability
        self.reason = reason
        self.timestamp = timestamp
    }
}

public enum ControlEvent: String, Codable, Sendable {
    case discovered
    case helperUnavailable
    case helperRecovered
    case systemWake
    case systemSleep
    case sensorFault
    case sensorRecovered
    case manualDefault
    case appBoostStart
    case appBoostStop
    case userModeChange
    case systemEvent
    case safetyTriggered
    case safetyRecovered
}

public struct ThermalControlConfigValidationReport: Codable, Sendable {
    public var isValid: Bool
    public var reason: String

    public init(isValid: Bool, reason: String = "ok") {
        self.isValid = isValid
        self.reason = reason
    }
}
