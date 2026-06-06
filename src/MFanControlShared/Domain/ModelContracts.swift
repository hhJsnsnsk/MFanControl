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
        sustainedLoadSec: Double? = nil
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
    }
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
}
