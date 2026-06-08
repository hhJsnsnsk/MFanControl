import Foundation

public struct SensorChannelAvailability: Codable, Sendable {
    public var available: Bool
    public var confidence: Double
    public var reason: String

    public init(available: Bool, confidence: Double, reason: String = "") {
        self.available = available
        self.confidence = min(1, max(0, confidence))
        self.reason = reason
    }
}

public struct ThermalThrottleState: Codable, Sendable {
    public var cpuThermalThrottled: Bool
    public var gpuThermalThrottled: Bool
    public var reason: String

    public init(cpuThermalThrottled: Bool, gpuThermalThrottled: Bool, reason: String = "") {
        self.cpuThermalThrottled = cpuThermalThrottled
        self.gpuThermalThrottled = gpuThermalThrottled
        self.reason = reason
    }

    public var isThrottling: Bool {
        cpuThermalThrottled || gpuThermalThrottled
    }
}

public struct SensorSampleOutput: Sendable {
    public var sample: SensorSample
    public var availability: [String: SensorChannelAvailability]
    public var throttleState: ThermalThrottleState
    public var powerSource: String

    public init(
        sample: SensorSample,
        availability: [String: SensorChannelAvailability] = [:],
        throttleState: ThermalThrottleState = .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: ""),
        powerSource: String = "unknown"
    ) {
        self.sample = sample
        self.availability = availability
        self.throttleState = throttleState
        self.powerSource = powerSource
    }

    public static func unavailable(sample: SensorSample = .init(timestamp: Date()), reason: String = "unavailable") -> SensorSampleOutput {
        let unavailable = SensorChannelAvailability(available: false, confidence: 0, reason: reason)
        return SensorSampleOutput(
            sample: sample,
            availability: [
                "cpu": unavailable,
                "gpu": unavailable,
                "soc": unavailable,
                "ssd": unavailable,
                "battery": unavailable,
                "memory": unavailable,
                "power": unavailable
            ],
            throttleState: ThermalThrottleState(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: reason),
            powerSource: "unknown"
        )
    }
}

public protocol SensorSampler {
    func nextSample(at timestamp: Date) -> SensorSampleOutput
}

public final class DeterministicSensorSampler: SensorSampler {
    private var counter = 0

    public init() {}

    public func nextSample(at timestamp: Date) -> SensorSampleOutput {
        counter += 1
        let cpu = 40 + Double(counter % 20)
        let ecore = 38 + Double(counter % 16)
        let gpu = 41 + Double(counter % 18)
        let soc = 39 + Double(counter % 22)
        let sample = SensorSample(
            timestamp: timestamp,
            cpuPcoreTempC: cpu,
            cpuEcoreTempC: ecore,
            gpuTempC: gpu,
            socTempC: soc,
            ssdTempC: 34 + Double(counter % 10),
            batteryTempC: 35 + Double(counter % 8),
            memoryTempC: 40 + Double(counter % 12),
            powerWatts: 12 + Double((counter * 3) % 45),
            sustainedLoadSec: min(30, Double(counter * 2))
        )
        let conf = SensorChannelAvailability(available: true, confidence: 0.95, reason: "deterministic-sampler")
        let availability: [String: SensorChannelAvailability] = [
            "cpu": conf,
            "gpu": conf,
            "soc": conf,
            "ssd": conf,
            "power": conf
        ]
        return SensorSampleOutput(
            sample: sample,
            availability: availability,
            throttleState: .init(cpuThermalThrottled: false, gpuThermalThrottled: false),
            powerSource: "AC"
        )
    }
}

public struct SensorReadingSources {
    public static let cpu = "cpu"
    public static let gpu = "gpu"
    public static let soc = "soc"
    public static let ssd = "ssd"
    public static let power = "power"
    public static let battery = "battery"
    public static let memory = "memory"
}

public struct SensorDisplayReading: Sendable {
    public var id: String
    public var label: String
    public var valueC: Double?
    public var available: Bool
    public var confidence: Double
    public var reason: String

    public init(
        id: String,
        label: String,
        valueC: Double?,
        available: Bool,
        confidence: Double,
        reason: String
    ) {
        self.id = id
        self.label = label
        self.valueC = valueC
        self.available = available
        self.confidence = confidence
        self.reason = reason
    }
}

public protocol RawTemperatureSensorSource {
    func readRawTemperatureSensors() -> [RawTemperatureSensorReading]
}

public struct EmptyRawTemperatureSensorSource: RawTemperatureSensorSource {
    public init() {}

    public func readRawTemperatureSensors() -> [RawTemperatureSensorReading] {
        []
    }
}

public final class HIDTemperatureSensorSource: RawTemperatureSensorSource {
    private static let temperatureUsagePage = 0xff00
    private static let temperatureUsage = 5
    private static let temperatureEventType: Int64 = 15
    private static let temperatureEventField: Int32 = Int32(15 << 16)

    // Cached client — creating a new IOHIDEventSystemClient on every poll leaks ~19 KB/tick.
    // The client is safe to reuse; services are re-enumerated each call to catch sensor changes.
    private var cachedClient: CFTypeRef?

    public init() {}

    public func readRawTemperatureSensors() -> [RawTemperatureSensorReading] {
        return autoreleasepool {
            let client: CFTypeRef
            if let existing = cachedClient {
                client = existing
            } else {
                guard let fresh = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return [] }
                let matching = [
                    "PrimaryUsagePage": Self.temperatureUsagePage,
                    "PrimaryUsage": Self.temperatureUsage
                ] as CFDictionary
                IOHIDEventSystemClientSetMatching(fresh, matching)
                cachedClient = fresh
                client = fresh
            }
            guard let services = IOHIDEventSystemClientCopyServices(client) else { return [] }
            var readings: [RawTemperatureSensorReading] = []
            for index in 0..<CFArrayGetCount(services) {
                let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: CFTypeRef.self)
                let product = IOHIDServiceClientCopyProperty(service, "Product" as CFString) as? String
                guard let name = product, !name.isEmpty else { continue }
                guard let event = IOHIDServiceClientCopyEvent(service, Self.temperatureEventType, 0, 0) else { continue }
                let temp = IOHIDEventGetFloatValue(event, Self.temperatureEventField)
                guard temp.isFinite, temp > -50, temp < 150 else { continue }
                readings.append(RawTemperatureSensorReading(name: name, tempC: temp))
            }
            return readings.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }
}

@_silgen_name("IOHIDEventSystemClientCreate")
private func IOHIDEventSystemClientCreate(_ allocator: CFAllocator?) -> CFTypeRef?

@_silgen_name("IOHIDEventSystemClientSetMatching")
private func IOHIDEventSystemClientSetMatching(_ client: CFTypeRef, _ matching: CFDictionary)

@_silgen_name("IOHIDEventSystemClientCopyServices")
private func IOHIDEventSystemClientCopyServices(_ client: CFTypeRef) -> CFArray?

@_silgen_name("IOHIDServiceClientCopyProperty")
private func IOHIDServiceClientCopyProperty(_ service: CFTypeRef, _ key: CFString) -> CFTypeRef?

@_silgen_name("IOHIDServiceClientCopyEvent")
private func IOHIDServiceClientCopyEvent(_ service: CFTypeRef, _ type: Int64, _ options: Int32, _ timeout: Int64) -> CFTypeRef?

@_silgen_name("IOHIDEventGetFloatValue")
private func IOHIDEventGetFloatValue(_ event: CFTypeRef, _ field: Int32) -> Double

public extension SensorSample {
    func temperatureReadings(availability: [String: SensorChannelAvailability] = [:]) -> [SensorDisplayReading] {
        let channels: [(id: String, label: String, value: Double?, availabilityKey: String)] = [
            ("cpu_pcore", "CPU P-core", cpuPcoreTempC, SensorReadingSources.cpu),
            ("cpu_ecore", "CPU E-core", cpuEcoreTempC, "cpu_ecore"),
            ("gpu", "GPU", gpuTempC, SensorReadingSources.gpu),
            ("soc", "SoC", socTempC, SensorReadingSources.soc),
            ("ssd", "SSD", ssdTempC, SensorReadingSources.ssd),
            ("battery", "Battery", batteryTempC, SensorReadingSources.battery),
            ("memory", "Memory", memoryTempC, SensorReadingSources.memory)
        ]

        let mapped = channels.map { channel in
            let state = availability[channel.availabilityKey]
            let valueAvailable = channel.value != nil
            let channelAvailable = state?.available ?? valueAvailable
            let unavailableReason: String
            if let reason = state?.reason, !reason.isEmpty {
                unavailableReason = reason
            } else {
                unavailableReason = "not-sampled"
            }
            return SensorDisplayReading(
                id: channel.id,
                label: channel.label,
                valueC: channel.value,
                available: valueAvailable && channelAvailable,
                confidence: state?.confidence ?? (valueAvailable ? 1 : 0),
                reason: valueAvailable ? (state?.reason ?? "") : unavailableReason
            )
        }

        let rawReadings = rawTemperatureSensors.map {
            SensorDisplayReading(
                id: "raw:\($0.name)",
                label: Self.friendlyRawSensorLabel(for: $0.name),
                valueC: $0.tempC,
                available: true,
                confidence: 0.85,
                reason: ""
            )
        }

        return mapped + rawReadings
    }

    func hottestTemperatureReading(availability: [String: SensorChannelAvailability] = [:]) -> SensorDisplayReading? {
        temperatureReadings(availability: availability)
            .filter { $0.available }
            .max { ($0.valueC ?? -.infinity) < ($1.valueC ?? -.infinity) }
    }
}

private extension SensorSample {
    static func friendlyRawSensorLabel(for name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Unknown Sensor"
        }

        let normalized = trimmed.replacingOccurrences(of: "_", with: " ")
        let lower = normalized.lowercased()

        let explicitMap: [String: String] = [
            "nand ch0 temp": "NAND CH0",
            "nand ch1 temp": "NAND CH1",
            "nand ch2 temp": "NAND CH2",
            "nand ch3 temp": "NAND CH3"
        ]
        if let mapped = explicitMap[lower] {
            return mapped
        }

        let parts = lower.split(separator: " ")
        guard parts.count >= 2, let bus = parts.first, bus.hasPrefix("pmu") else {
            return normalized
                .split(separator: " ")
                .map { $0.capitalized }
                .joined(separator: " ")
        }

        let busLabel = bus.uppercased()
        let sensor = String(parts[1])
        if sensor.hasPrefix("tdie") {
            let index = String(sensor.dropFirst("tdie".count))
            return "\(busLabel) DIE \(index.isEmpty ? "Temp" : index)"
        }
        if sensor.hasPrefix("tdev") {
            let index = String(sensor.dropFirst("tdev".count))
            return "\(busLabel) Device \(index.isEmpty ? "Sensor" : index)"
        }
        if sensor.hasPrefix("tcal") {
            return "\(busLabel) Calibration"
        }

        return "\(busLabel) \(sensor.prefix(1).uppercased())\(sensor.dropFirst())"
    }
}

public struct SensorReadContext {
    public let timestamp: Date
    public var samples: SensorSample
    public var availability: [String: SensorChannelAvailability]
    public var powerSource: String
    public var throttleState: ThermalThrottleState

    public init(
        timestamp: Date,
        samples: SensorSample = .init(timestamp: Date()),
        availability: [String: SensorChannelAvailability] = [:],
        powerSource: String = "unknown",
        throttleState: ThermalThrottleState = .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "")
    ) {
        self.timestamp = timestamp
        self.samples = samples
        self.availability = availability
        self.powerSource = powerSource
        self.throttleState = throttleState
    }
}

public final class SystemSensorSampler: SensorSampler {
    private let rawTemperatureSensorSource: any RawTemperatureSensorSource
    private var lastSampleAt: Date?
    private var sustainedLoad: Double = 0
    private static let loadWindow: Double = 30

    public init(
        rawTemperatureSensorSource: any RawTemperatureSensorSource = HIDTemperatureSensorSource()
    ) {
        self.rawTemperatureSensorSource = rawTemperatureSensorSource
    }

    public func nextSample(at timestamp: Date) -> SensorSampleOutput {
        var sample = SensorSample(timestamp: timestamp)
        // All temperatures read directly via IOHIDEventSystem — no subprocesses
        sample.rawTemperatureSensors = rawTemperatureSensorSource.readRawTemperatureSensors()
        sample = enrichWithRawTemperatureFallback(sample)
        // Power watts via HID power sensors
        sample.powerWatts = HIDPowerSensorSource().readTotalPowerWatts()
        // Power source via IOKit — no subprocess
        let powerSrc = IOKitPowerSourceReader.powerSourceString()
        let availability = availability(for: sample)
        let finalSample = withSustainedLoad(sample, timestamp: timestamp)
        return SensorSampleOutput(
            sample: finalSample,
            availability: availability,
            throttleState: throttleState(for: finalSample),
            powerSource: powerSrc
        )
    }

    private func availability(for sample: SensorSample) -> [String: SensorChannelAvailability] {
        [
            SensorReadingSources.cpu: SensorChannelAvailability(
                available: sample.cpuPcoreTempC != nil,
                confidence: sample.cpuPcoreTempC == nil ? 0 : 0.75,
                reason: sample.cpuPcoreTempC == nil ? "cpu-temp-unavailable" : ""
            ),
            SensorReadingSources.gpu: SensorChannelAvailability(
                available: sample.gpuTempC != nil,
                confidence: sample.gpuTempC == nil ? 0 : 0.72,
                reason: sample.gpuTempC == nil ? "gpu-temp-unavailable" : ""
            ),
            SensorReadingSources.soc: SensorChannelAvailability(
                available: sample.socTempC != nil,
                confidence: sample.socTempC == nil ? 0 : 0.72,
                reason: sample.socTempC == nil ? "soc-temp-unavailable" : ""
            ),
            SensorReadingSources.ssd: SensorChannelAvailability(
                available: sample.ssdTempC != nil,
                confidence: sample.ssdTempC == nil ? 0 : 0.55,
                reason: sample.ssdTempC == nil ? "ssd-temp-unavailable" : ""
            ),
            SensorReadingSources.battery: SensorChannelAvailability(
                available: sample.batteryTempC != nil,
                confidence: sample.batteryTempC == nil ? 0 : 0.55,
                reason: sample.batteryTempC == nil ? "battery-temp-unavailable" : ""
            ),
            SensorReadingSources.memory: SensorChannelAvailability(
                available: sample.memoryTempC != nil,
                confidence: sample.memoryTempC == nil ? 0 : 0.55,
                reason: sample.memoryTempC == nil ? "memory-temp-unavailable" : ""
            ),
            SensorReadingSources.power: SensorChannelAvailability(
                available: sample.powerWatts != nil,
                confidence: sample.powerWatts == nil ? 0 : 0.6,
                reason: sample.powerWatts == nil ? "power-missing" : ""
            )
        ]
    }

    private func throttleState(for sample: SensorSample) -> ThermalThrottleState {
        guard
            let cpu = sample.cpuPcoreTempC,
            let gpu = sample.gpuTempC,
            let soc = sample.socTempC
        else {
            return ThermalThrottleState(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "insufficient-temp-data")
        }
        let cpuThrottled = cpu >= 98 || soc >= 98
        let gpuThrottled = gpu >= 98
        let reason = (cpuThrottled || gpuThrottled) ? "high-temp-threshold" : ""
        return ThermalThrottleState(cpuThermalThrottled: cpuThrottled, gpuThermalThrottled: gpuThrottled, reason: reason)
    }

    private func withSustainedLoad(_ sample: SensorSample, timestamp: Date) -> SensorSample {
        var value = sample
        if let last = lastSampleAt {
            let dt = max(0, timestamp.timeIntervalSince(last))
            if let temp = sample.cpuPcoreTempC ?? sample.gpuTempC ?? sample.socTempC {
                let shouldAccumulate = temp >= 75
                if shouldAccumulate {
                    sustainedLoad = min(Self.loadWindow, sustainedLoad + dt)
                } else {
                    sustainedLoad = max(0, sustainedLoad - dt * 0.5)
                }
            } else {
                sustainedLoad = max(0, sustainedLoad - dt)
            }
        } else {
            sustainedLoad = 0
        }
        lastSampleAt = timestamp
        value.sustainedLoadSec = sustainedLoad
        return value
    }

    private func enrichWithRawTemperatureFallback(_ sample: SensorSample) -> SensorSample {
        var output = sample
        guard !sample.rawTemperatureSensors.isEmpty else { return output }
        // On Apple Silicon Macs (M1–M4) the named SMC keys for CPU/GPU/SoC are often
        // absent or unreliable; PMU DIE sensors are the authoritative source.
        // ADR 0006: mapping is acceptable here because it is hardware-validated for all
        // currently supported Apple Silicon models (M1–M4). Revisit for new chip families.
        let raw = sample.rawTemperatureSensors
        if output.cpuPcoreTempC == nil {
            output.cpuPcoreTempC = maxRaw(from: raw, where: { $0.name.localizedCaseInsensitiveContains("PMU") || $0.name.localizedCaseInsensitiveContains("PMU2") })
        }
        if output.gpuTempC == nil {
            output.gpuTempC = maxRaw(from: raw, where: { $0.name.localizedCaseInsensitiveContains("PMU2") || $0.name.localizedCaseInsensitiveContains("PMU Device") })
        }
        if output.socTempC == nil {
            output.socTempC = maxRaw(from: raw, where: { $0.name.localizedCaseInsensitiveContains("PMU") || $0.name.localizedCaseInsensitiveContains("PMU2") })
        }
        if output.ssdTempC == nil {
            output.ssdTempC = maxRaw(from: raw, where: { $0.name.localizedCaseInsensitiveContains("NAND") || $0.name.localizedCaseInsensitiveContains("SSD") })
        }
        if output.memoryTempC == nil {
            output.memoryTempC = maxRaw(from: raw, where: { $0.name.localizedCaseInsensitiveContains("PMU2 Device") })
        }
        return output
    }

    private func maxRaw(from readings: [RawTemperatureSensorReading], where predicate: (RawTemperatureSensorReading) -> Bool) -> Double? {
        let values = readings.filter(predicate).map(\.tempC)
        return values.isEmpty ? nil : values.max()
    }
}

// Reads system power source (AC/Battery) via IOKit — no subprocess needed.
public struct IOKitPowerSourceReader {
    public static func powerSourceString() -> String {
        // IOPSCopyPowerSourcesInfo is available in IOKit framework
        let lib = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_NOLOAD)
        defer { if let lib { dlclose(lib) } }
        guard let lib,
              let sym = dlsym(lib, "IOPSCopyPowerSourcesInfo"),
              let listSym = dlsym(lib, "IOPSCopyPowerSourcesList"),
              let descSym = dlsym(lib, "IOPSGetPowerSourceDescription") else { return "AC" }
        typealias InfoFn = @convention(c) () -> CFTypeRef?
        typealias ListFn = @convention(c) (CFTypeRef) -> CFArray?
        typealias DescFn = @convention(c) (CFTypeRef, CFTypeRef) -> CFDictionary?
        let infoFn = unsafeBitCast(sym, to: InfoFn.self)
        let listFn = unsafeBitCast(listSym, to: ListFn.self)
        let descFn = unsafeBitCast(descSym, to: DescFn.self)
        guard let blob = infoFn() else { return "AC" }
        guard let list = listFn(blob) else { return "AC" }
        for i in 0..<CFArrayGetCount(list) {
            let ps = unsafeBitCast(CFArrayGetValueAtIndex(list, i), to: CFTypeRef.self)
            guard let desc = descFn(blob, ps) as? [String: Any] else { continue }
            if let state = desc["Power Source State"] as? String {
                if state.contains("Battery") { return "Battery" }
                if state.contains("AC") { return "AC" }
            }
        }
        return "AC"
    }
}

// Reads total system power watts via IOHIDEventSystem (Apple Silicon M-series).
// Returns nil gracefully if sensors are unavailable.
public struct HIDPowerSensorSource {
    private static let powerUsagePage = 0xff08
    private static let powerUsage = 2
    private static let powerEventType: Int64 = 25
    private static let powerEventField: Int32 = Int32(25 << 16)

    public init() {}

    public func readTotalPowerWatts() -> Double? {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else { return nil }
        let matching = ["PrimaryUsagePage": Self.powerUsagePage, "PrimaryUsage": Self.powerUsage] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)
        guard let services = IOHIDEventSystemClientCopyServices(client) else { return nil }
        var total = 0.0
        var found = false
        for index in 0..<CFArrayGetCount(services) {
            let service = unsafeBitCast(CFArrayGetValueAtIndex(services, index), to: CFTypeRef.self)
            guard let event = IOHIDServiceClientCopyEvent(service, Self.powerEventType, 0, 0) else { continue }
            let watts = IOHIDEventGetFloatValue(event, Self.powerEventField)
            guard watts.isFinite, watts >= 0, watts < 1000 else { continue }
            total += watts
            found = true
        }
        return found ? total : nil
    }
}


public final class FallbackSensorSampler: SensorSampler {
    private let deterministic = DeterministicSensorSampler()

    public init() {}

    public func nextSample(at timestamp: Date) -> SensorSampleOutput {
        deterministic.nextSample(at: timestamp)
    }
}
