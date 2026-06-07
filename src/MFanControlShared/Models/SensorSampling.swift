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

public struct HIDTemperatureSensorSource: RawTemperatureSensorSource {
    private static let temperatureUsagePage = 0xff00
    private static let temperatureUsage = 5
    private static let temperatureEventType: Int64 = 15
    private static let temperatureEventField: Int32 = Int32(15 << 16)

    public init() {}

    public func readRawTemperatureSensors() -> [RawTemperatureSensorReading] {
        guard let client = IOHIDEventSystemClientCreate(kCFAllocatorDefault) else {
            return []
        }

        let matching = [
            "PrimaryUsagePage": Self.temperatureUsagePage,
            "PrimaryUsage": Self.temperatureUsage
        ] as CFDictionary
        IOHIDEventSystemClientSetMatching(client, matching)

        guard let services = IOHIDEventSystemClientCopyServices(client) else {
            return []
        }

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
    private struct CommandRunner {
        let command: (String, [String]) -> String?
    }

    private var commandRunner: CommandRunner
    private let rawTemperatureSensorSource: any RawTemperatureSensorSource
    private var lastSampleAt: Date?
    private var sustainedLoad: Double = 0
    private static let loadWindow: Double = 30

    public init(
        runShell: @escaping (String, [String]) -> String? = SystemSensorSampler.defaultRunShell,
        rawTemperatureSensorSource: any RawTemperatureSensorSource = HIDTemperatureSensorSource()
    ) {
        self.commandRunner = CommandRunner(command: runShell)
        self.rawTemperatureSensorSource = rawTemperatureSensorSource
    }

    public func nextSample(at timestamp: Date) -> SensorSampleOutput {
        let powermetrics = commandRunner.command("/usr/bin/env", ["powermetrics", "-n", "1", "-i", "1000", "-s", "thermal,cpu_power,gpu_power"])
        let pmsetTherm = commandRunner.command("/usr/bin/env", ["pmset", "-g", "therm"])
        let batt = commandRunner.command("/usr/bin/env", ["pmset", "-g", "batt"])
        var parsed = parseSample(fromPowermetrics: powermetrics, pmset: pmsetTherm, timestamp: timestamp)
        parsed.rawTemperatureSensors = rawTemperatureSensorSource.readRawTemperatureSensors()
        let power = powerSource(from: batt)
        let availability = availability(for: parsed)
        let finalSample = withSustainedLoad(parsed, timestamp: timestamp)

        return SensorSampleOutput(
            sample: finalSample,
            availability: availability,
            throttleState: throttleState(for: finalSample),
            powerSource: power
        )
    }

    public static func defaultRunShell(_ launchPath: String, _ arguments: [String]) -> String? {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    private func parseSample(fromPowermetrics: String?, pmset: String?, timestamp: Date) -> SensorSample {
        var sample = SensorSample(timestamp: timestamp)
        sample.cpuPcoreTempC = readTemp(from: fromPowermetrics, keys: ["cpu", "cpu die", "processor"]) ??
            readTemp(from: pmset, keys: ["cpu", "cpu die"])
        sample.cpuEcoreTempC = nil
        sample.gpuTempC = readTemp(from: fromPowermetrics, keys: ["gpu", "gpu die"]) ??
            readTemp(from: pmset, keys: ["gpu"])
        sample.socTempC = readTemp(from: fromPowermetrics, keys: ["soc"]) ??
            readTemp(from: pmset, keys: ["soc"])
        sample.ssdTempC = readTemp(from: pmset, keys: ["ssd", "ssd temp", "nvme"]) ??
            readTemp(from: fromPowermetrics, keys: ["ssd"])
        sample.powerWatts = readPower(from: fromPowermetrics, keys: ["power", "watts"]) ??
            readPower(from: pmset, keys: ["power", "W"])
        return sample
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

    private func readTemp(from text: String?, keys: [String]) -> Double? {
        guard let text else { return nil }
        for key in keys {
            if let found = firstTemperature(in: text, near: key) {
                return found
            }
        }
        return nil
    }

    private func readPower(from text: String?, keys: [String]) -> Double? {
        guard let text else { return nil }
        for key in keys {
            if let found = firstPower(in: text, near: key) {
                return found
            }
        }
        return nil
    }

    private func firstTemperature(in text: String, near anchor: String) -> Double? {
        do {
            let escaped = NSRegularExpression.escapedPattern(for: anchor)
            let expr = try NSRegularExpression(pattern: "(?i)\(escaped)[^0-9-\\.]*(-?\\d+(?:\\.\\d+)?)\\s*°?c")
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expr.firstMatch(in: text, options: [], range: range) {
                let valueRange = Range(match.range(at: 1), in: text).flatMap { Double(text[$0]) }
                if let value = valueRange {
                    return value
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private func firstPower(in text: String, near anchor: String) -> Double? {
        do {
            let escaped = NSRegularExpression.escapedPattern(for: anchor)
            let expr = try NSRegularExpression(pattern: "(?i)\(escaped)[^0-9-\\.]*(-?\\d+(?:\\.\\d+)?)\\s*(mw|w|watt|watts)")
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if let match = expr.firstMatch(in: text, options: [], range: range) {
                let valueRange = Range(match.range(at: 1), in: text).flatMap { Double(text[$0]) }
                let unitRange = Range(match.range(at: 2), in: text).map { String(text[$0]).lowercased() }
                if let value = valueRange {
                    return unitRange == "mw" ? value / 1000.0 : value
                }
            }
        } catch {
            return nil
        }
        return nil
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

    private func powerSource(from text: String?) -> String {
        guard let text else { return "unknown" }
        if text.range(of: "AC Power", options: .caseInsensitive) != nil { return "AC" }
        if text.range(of: "Battery Power", options: .caseInsensitive) != nil { return "Battery" }
        return "unknown"
    }
}

public final class FallbackSensorSampler: SensorSampler {
    private let deterministic = DeterministicSensorSampler()

    public init() {}

    public func nextSample(at timestamp: Date) -> SensorSampleOutput {
        deterministic.nextSample(at: timestamp)
    }
}
