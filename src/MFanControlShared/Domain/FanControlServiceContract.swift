import Foundation

public protocol FanControlServiceProtocol: AnyObject {
    func currentState() -> FanControlSnapshot
    func apply(_ command: ControlCommand) -> FanControlResult
    func restoreToAppleDefault(reason: String) -> FanControlResult
    func enterSafetyFallback(reason: String) -> FanControlResult
    func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult
    func discoverHardwareProfile() -> HardwareProfile
    func readSensorSample() -> SensorSample
    func exportConfig() -> ThermalControlConfig
    func importConfig(_ config: ThermalControlConfig) -> FanControlResult
    func recentSamples(limit: Int) -> [TelemetrySampleRecord]
    func recentEvents(limit: Int) -> [TelemetryEventRecord]
    func resetForUninstall() -> FanControlResult
    func handleSystemWake() -> FanControlResult
    func handleSystemSleep() -> FanControlResult
}

public extension FanControlServiceProtocol {
    func enterSafetyFallback(reason: String) -> FanControlResult {
        restoreToAppleDefault(reason: "safety-fallback:\(reason)")
    }
}

private enum FanControlRuntimeServiceKeys {
    static let helperServiceLabel = "com.starrysky.MFanControlHelper.xpc"
}

public final class FanControlRuntimeService: FanControlServiceProtocol {
    public private(set) var configuration: ThermalControlConfig
    public private(set) var stateMachine: ControlStateMachine
    public private(set) var hardwareProfile: HardwareProfile
    public private(set) var currentRPM: Int
    public private(set) var targetRPM: Int
    public private(set) var activeMode: ThermalPolicy.Mode
    public private(set) var appBoostUntil: Date?
    public private(set) var lastReason: String
    public private(set) var lastObservedThermalScore: Double?
    public private(set) var telemetryStore: TelemetryStoreProtocol
    private let sensorSampler: SensorSampler
    private var lastSampleAvailability: [String: SensorChannelAvailability]
    private var lastThrottleState: ThermalThrottleState
    private var lastPowerSource: String
    private var lastSampleAt: Date?
    private var lastSustainedLoad: Double
    private var safetyViolationStartedAt: Date?
    private var lastApplyAt: Date
    private let minApplyInterval: TimeInterval
    private let uninstallCleanup: () -> Bool
    private var scorer = ThermalScoringEngine()
    private var previousScore: Double?
    private let configStore: ConfigStore

    public static let shared = FanControlRuntimeService()

    public init(
        configuration: ThermalControlConfig = ThermalControlConfig(),
        hardwareProfile: HardwareProfile = HardwareDiscovery.detect(),
        initialRPM: Int? = nil,
        sensorSampler: SensorSampler = SystemSensorSampler(),
        telemetryStore: TelemetryStoreProtocol = PersistentTelemetryStore(),
        configStore: ConfigStore = ConfigStore(),
        uninstallCleanup: @escaping () -> Bool = FanControlRuntimeService.defaultUninstallCleanup
    ) {
        self.configStore = configStore
        let initialConfiguration = configuration
        if let persisted = configStore.get(ThermalControlConfig.self, forKey: ConfigStoreKeys.thermalConfig),
           persisted.isValid() {
            self.configuration = persisted
        } else {
            self.configuration = initialConfiguration
        }
        self.hardwareProfile = hardwareProfile
        self.stateMachine = ControlStateMachine()
        self.activeMode = .balanced
        self.currentRPM = initialRPM ?? (hardwareProfile.fans.first?.minRPM ?? 1200)
        self.targetRPM = currentRPM
        self.lastReason = "init"
        self.telemetryStore = telemetryStore
        self.telemetryStore.reconfigureRetention(
            historyRetention: self.configuration.historyRetention,
            eventDebounceMinutes: self.configuration.safetyThresholds.safetyReasonDebounceMinutes
        )
        self.sensorSampler = sensorSampler
        self.lastSampleAvailability = [:]
        self.lastThrottleState = .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "init")
        self.lastPowerSource = "unknown"
        self.lastSustainedLoad = 0
        self.safetyViolationStartedAt = nil
        self.lastApplyAt = .distantPast
        self.minApplyInterval = 3.0
        self.uninstallCleanup = uninstallCleanup
        activeMode = ThermalPolicy.Mode(rawValue: self.configuration.profile) ?? .balanced
        self.configuration.profile = activeMode.rawValue
        _ = stateMachine.apply(event: .discovered, hardwareProfile: hardwareProfile)
        lastReason = reasonForDiscovery(hardwareProfile)
    }

    public func currentState() -> FanControlSnapshot {
        FanControlSnapshot(
            state: stateMachine.state,
            source: stateMachine.source,
            hardwareProfile: hardwareProfile,
            activeProfile: activeMode.rawValue,
            currentRPM: currentRPM,
            targetRPM: targetRPM,
            appBoostActive: isAppBoostActive(at: Date()),
            thermalScore: lastObservedThermalScore,
            powerSource: lastPowerSource,
            throttleState: lastThrottleState,
            sensorAvailability: lastSampleAvailability,
            reason: lastReason
        )
    }

    public func apply(_ command: ControlCommand) -> FanControlResult {
        let controllableFans = hardwareProfile.fans.filter { $0.controllable }
        guard hardwareProfile.hasFans && !controllableFans.isEmpty else {
            _ = stateMachine.apply(event: .discovered, hardwareProfile: hardwareProfile)
            lastReason = "hardware-not-controllable"
            return FanControlResult(
                success: false,
                reason: lastReason,
                failure: .notAvailable,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }

        let isManualRequest = command.reason == "cli-set-rpm" || command.reason == "emergency-set-rpm"
        guard isManualRequest || hardwareAvailableForControl() else {
            _ = stateMachine.apply(event: .sensorFault)
            lastReason = "sensor-fault"
            telemetryStore.appendEvent(
                TelemetryEventRecord(
                    state: stateMachine.state.rawValue,
                    level: "warn",
                    reason: "sensor-fault",
                    payload: ["action": "apply-blocked", "mode": activeMode.rawValue]
                )
            )
            return FanControlResult(
                success: false,
                reason: lastReason,
                failure: .hardwareUnreachable,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }

        guard stateMachine.state != .safetyFallback else {
            lastReason = "safety-mode-blocked"
            return FanControlResult(
                success: false,
                reason: lastReason,
                failure: .notAvailable,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }

        guard command.targetRPM >= 0 else {
            lastReason = "invalid-rpm"
            return FanControlResult(
                success: false,
                reason: lastReason,
                failure: .invalidCommand,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }

        let now = Date()
        if !isManualRequest, command.action == .setProfile, now.timeIntervalSince(lastApplyAt) < minApplyInterval {
            lastReason = "command-throttled"
            telemetryStore.appendEvent(
                TelemetryEventRecord(
                    state: stateMachine.state.rawValue,
                    level: "info",
                    reason: lastReason,
                    payload: ["interval": "\(now.timeIntervalSince(lastApplyAt))", "targetRPM": "\(command.targetRPM)"]
                )
            )
            return FanControlResult(
                success: true,
                reason: lastReason,
                state: stateMachine.state,
                source: stateMachine.source,
                timestamp: now
            )
        }
        lastApplyAt = now

        let minCap = command.minRPM ?? controllableFans.minRPM()
        let maxCap = command.maxRPM ?? controllableFans.maxRPM()
        let constrained = min(max(minCap, command.targetRPM), maxCap)
        let step = max(1, command.rampStep ?? 300)
        let delta = constrained - currentRPM
        let move = min(abs(delta), step) * (delta >= 0 ? 1 : -1)

        targetRPM = constrained
        if move != 0 {
            currentRPM = min(max(minCap, currentRPM + move), maxCap)
        }

        stateMachine.source = .appAuto
        if stateMachine.state == .idle || stateMachine.state == .manualDefault || stateMachine.state == .discovering {
            _ = stateMachine.apply(event: .systemEvent)
            stateMachine.state = .smartControl
        }

        lastReason = command.reason ?? "apply-command"
        telemetryStore.append(
            TelemetrySampleRecord(
                thermalScore: lastObservedThermalScore ?? Double(currentRPM),
                source: "app",
                reason: lastReason
            )
        )
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "info",
                reason: lastReason,
                payload: [
                    "command": command.action.rawValue,
                    "targetRPM": "\(command.targetRPM)",
                    "appliedRPM": "\(currentRPM)"
                ]
            )
        )

        return FanControlResult(
            success: true,
            reason: lastReason,
            state: stateMachine.state,
            source: stateMachine.source,
            timestamp: Date()
        )
    }

    public func enterSafetyFallback(reason: String) -> FanControlResult {
        _ = stateMachine.apply(event: .safetyTriggered)
        currentRPM = hardwareProfile.fans.first?.minRPM ?? 0
        targetRPM = currentRPM
        appBoostUntil = nil
        lastObservedThermalScore = nil
        lastReason = reason
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "error",
                reason: reason,
                payload: ["action": "restore-default"]
            )
        )
        return FanControlResult(
            success: true,
            reason: reason,
            state: stateMachine.state,
            source: stateMachine.source,
            timestamp: Date()
        )
    }

    public func restoreToAppleDefault(reason: String) -> FanControlResult {
        _ = stateMachine.apply(event: .manualDefault)
        currentRPM = hardwareProfile.fans.first?.minRPM ?? 0
        targetRPM = currentRPM
        appBoostUntil = nil
        lastObservedThermalScore = nil
        lastReason = reason
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "warn",
                reason: reason,
                payload: ["action": "restore-default"]
            )
        )
        return FanControlResult(
            success: true,
            reason: reason,
            state: stateMachine.state,
            source: .userManual,
            timestamp: Date()
        )
    }

    public func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        guard ThermalPolicy.Mode.allCases.contains(mode) else {
            lastReason = "unsupported-mode"
            return FanControlResult(
                success: false,
                reason: lastReason,
                failure: .invalidCommand,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }

        activeMode = mode
        configuration.profile = mode.rawValue
        configStore.set(configuration, forKey: ConfigStoreKeys.thermalConfig)
        stateMachine.setMode(mode)
        _ = stateMachine.apply(event: .userModeChange)
        lastReason = "set-mode:\(mode.rawValue)"
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "info",
                reason: lastReason,
                payload: ["mode": mode.rawValue]
            )
        )

        return FanControlResult(
            success: true,
            reason: lastReason,
            state: stateMachine.state,
            source: stateMachine.source,
            timestamp: Date()
        )
    }

    public func discoverHardwareProfile() -> HardwareProfile {
        _ = stateMachine.apply(event: .discovered, hardwareProfile: hardwareProfile)
        lastReason = reasonForDiscovery(hardwareProfile)
        return hardwareProfile
    }

    public func readSensorSample() -> SensorSample {
        let output = sensorSampler.nextSample(at: Date())
        var sample = output.sample

        updateLoadProfile(sample.timestamp)
        sample.sustainedLoadSec = lastSustainedLoad

        lastSampleAvailability = output.availability
        lastThrottleState = output.throttleState
        lastPowerSource = output.powerSource
        let score = scorer.compute(sample, previousScore: previousScore)
        previousScore = score.value
        lastObservedThermalScore = score.value
        evaluateSafetyState(from: score, sample: sample)

        if hardwareAvailableForControl() {
            if stateMachine.state == .idle {
                _ = stateMachine.apply(event: .sensorRecovered)
                telemetryStore.appendEvent(
                    TelemetryEventRecord(
                        state: stateMachine.state.rawValue,
                        level: "info",
                        reason: "sensor-recovered",
                        payload: ["count": "\(lastSampleAvailability.count)"]
                    )
                )
            }
        } else {
            _ = stateMachine.apply(event: .sensorFault)
            telemetryStore.appendEvent(
                TelemetryEventRecord(
                    state: stateMachine.state.rawValue,
                    level: "warn",
                    reason: "sensor-fault",
                    payload: ["action": "read-blocked", "sample-count": "1"]
                )
            )
        }

        if let currentSample = sample.cpuPcoreTempC,
           let maxSample = sample.gpuTempC,
           let cpuAvailability = output.availability[SensorReadingSources.cpu],
           cpuAvailability.available,
           currentSample > 0,
           maxSample >= 0 {
            if currentSample > 95 || maxSample > 95 {
                lastThrottleState = .init(
                    cpuThermalThrottled: currentSample > 95,
                    gpuThermalThrottled: maxSample > 95,
                    reason: "high-temperature"
                )
            }
        }

        let availabilityScore = lastSampleAvailability.values.filter { $0.available }.count
        if !lastSampleAvailability.isEmpty {
            telemetryStore.append(
                TelemetrySampleRecord(
                    thermalScore: Double(availabilityScore),
                    source: "sensor",
                    reason: "sample"
                )
            )
        }

        return sample
    }

    public func exportConfig() -> ThermalControlConfig {
        configuration
    }

    public func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        telemetryStore.fetchRecent(limit: limit)
    }

    public func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        telemetryStore.fetchRecentEvents(limit: limit)
    }

    public func resetForUninstall() -> FanControlResult {
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "warn",
                reason: "uninstall-sequence-start",
                payload: ["step": "restore-default"]
            )
        )
        let restored = restoreToAppleDefault(reason: "uninstall-sequence-start")
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "warn",
                reason: "uninstall-sequence-cleanup",
                payload: ["state": restored.state.rawValue]
            )
        )
        let cleanupResult = uninstallCleanup()
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: cleanupResult ? "info" : "warn",
                reason: "uninstall-sequence-cleanup-result",
                payload: ["success": "\(cleanupResult)"]
            )
        )
        configStore.removeAll()
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "warn",
                reason: "uninstall-sequence-clear",
                payload: ["step": "telemetry-cache"]
            )
        )
        telemetryStore.clear()
        if !cleanupResult {
            lastReason = "uninstall-sequence-complete-with-cleanup-warning"
        }
        return FanControlResult(
            success: true,
            reason: "uninstall-sequence-complete",
            state: restored.state,
            source: restored.source,
            timestamp: Date()
        )
    }

    public func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        let validation = config.validationReport()
        guard validation.isValid else {
            return FanControlResult(
                success: false,
                reason: "invalid-config: \(validation.reason)",
                failure: .invalidCommand,
                state: stateMachine.state,
                source: stateMachine.source
            )
        }
        let normalized = config.normalized()
        configuration = normalized
        telemetryStore.reconfigureRetention(
            historyRetention: normalized.historyRetention,
            eventDebounceMinutes: normalized.safetyThresholds.safetyReasonDebounceMinutes
        )
        activeMode = ThermalPolicy.Mode(rawValue: normalized.profile) ?? activeMode
        stateMachine.setMode(activeMode)
        configStore.set(normalized, forKey: ConfigStoreKeys.thermalConfig)
        return FanControlResult(
            success: true,
            reason: "config-imported",
            state: stateMachine.state,
            source: stateMachine.source
        )
    }

    public func handleSystemWake() -> FanControlResult {
        _ = stateMachine.apply(event: .systemWake)
        _ = discoverHardwareProfile()
        let sample = readSensorSample()
        if !sample.availableCriticalSensors() {
            lastReason = "system-wake-sensor-recovery-failed"
            telemetryStore.appendEvent(
                TelemetryEventRecord(
                    state: stateMachine.state.rawValue,
                    level: "warn",
                    reason: lastReason,
                    payload: ["action": "system-wake-recover"]
                )
            )
        }

        return FanControlResult(
            success: true,
            reason: lastReason,
            state: stateMachine.state,
            source: stateMachine.source,
            timestamp: Date()
        )
    }

    public func handleSystemSleep() -> FanControlResult {
        let result = restoreToAppleDefault(reason: "system-sleep")
        _ = stateMachine.apply(event: .systemSleep)
        telemetryStore.appendEvent(
            TelemetryEventRecord(
                state: stateMachine.state.rawValue,
                level: "info",
                reason: "system-sleep",
                payload: ["action": "restore-default"]
            )
        )
        return result
    }

    public func setAppBoost(until: Date) {
        appBoostUntil = until
    }

    public func isAppBoostActive(at now: Date) -> Bool {
        if let until = appBoostUntil, now <= until {
            return true
        }
        appBoostUntil = nil
        return false
    }

    private func hardwareAvailableForControl() -> Bool {
        if hardwareProfile.fans.filter({ $0.controllable }).isEmpty {
            return false
        }

        let critical: [String] = [
            SensorReadingSources.cpu,
            SensorReadingSources.gpu,
            SensorReadingSources.soc
        ]

        return critical.allSatisfy {
            lastSampleAvailability[$0]?.available == true
        }
    }

    private func updateLoadProfile(_ now: Date) {
        if let last = lastSampleAt {
            let gap = max(0, now.timeIntervalSince(last))
            if let _ = lastSampleAvailability[SensorReadingSources.cpu],
               lastSampleAvailability[SensorReadingSources.cpu]?.available == true {
                lastSustainedLoad = min(30, lastSustainedLoad + gap)
            } else {
                lastSustainedLoad = max(0, lastSustainedLoad - gap)
            }
        } else {
            lastSustainedLoad = 0
        }
        lastSampleAt = now
    }

    private func evaluateSafetyState(from score: ThermalScore, sample: SensorSample) {
        let safety = configuration.safetyThresholds
        let sustained = sample.sustainedLoadSec ?? 0
        let criticalTemps = [sample.cpuPcoreTempC, sample.cpuEcoreTempC, sample.gpuTempC, sample.socTempC].compactMap { $0 }
        let criticalHigh = criticalTemps.contains(where: { $0 >= 102 })

        if criticalHigh || (score.clampedValue >= safety.thermalSafetyScore && sustained >= safety.sustainedSeconds) {
            if stateMachine.state != .safetyFallback {
                _ = enterSafetyFallback(reason: criticalHigh ? "critical-thermal-threshold" : "sustained-thermal-score")
                safetyViolationStartedAt = Date()
            } else if safetyViolationStartedAt == nil {
                safetyViolationStartedAt = Date()
            }
            return
        }

        if stateMachine.state == .safetyFallback,
           let startedAt = safetyViolationStartedAt,
           score.clampedValue < max(0, safety.thermalSafetyScore - 8),
           sustained <= max(0, safety.sustainedSeconds / 2),
           Date().timeIntervalSince(startedAt) >= safety.sampleIntervalSec {
            _ = stateMachine.apply(event: .safetyRecovered)
            safetyViolationStartedAt = nil
            telemetryStore.appendEvent(
                TelemetryEventRecord(
                    state: stateMachine.state.rawValue,
                    level: "info",
                    reason: "safety-cleared",
                    payload: ["score": "\(score.clampedValue)"]
                )
            )
        }
    }

    private func reasonForDiscovery(_ profile: HardwareProfile) -> String {
        guard profile.isAppleSilicon else {
            return "non-apple-silicon"
        }
        let controllableFans = profile.fans.filter { $0.controllable }
        return controllableFans.isEmpty ? "hardware-not-controllable" : "hardware-discovered"
    }

    public static func defaultUninstallCleanup() -> Bool {
        let serviceName = ProcessInfo.processInfo.environment["MFANCONTROL_HELPER_SERVICE_NAME"] ?? FanControlRuntimeServiceKeys.helperServiceLabel
        let actions: [[String]] = [
            ["launchctl", "bootout", "system/\(serviceName)"],
            ["launchctl", "remove", serviceName],
            ["xcrun", "simctl", "uninstall", "booted", serviceName]
        ]
        let noOp = ProcessInfo.processInfo.environment["MFANCONTROL_NOOP_CLEANUP"] == "1"
        if noOp {
            return true
        }

        for command in actions {
            _ = runCleanupCommand(command)
        }
        return true
    }

    private static func runCleanupCommand(_ command: [String]) -> Bool {
        guard command.count >= 2 else { return true }
        let launchPath = "/usr/bin/env"
        let task = Process()
        task.launchPath = launchPath
        task.arguments = command
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}

private extension SensorSample {
    func availableCriticalSensors() -> Bool {
        [cpuPcoreTempC, gpuTempC, socTempC].allSatisfy { $0 != nil }
    }
}

private extension Array where Element == FanCapability {
    func minRPM() -> Int {
        self.map(\.minRPM).min() ?? 0
    }

    func maxRPM() -> Int {
        self.map(\.maxRPM).max() ?? 0
    }
}
