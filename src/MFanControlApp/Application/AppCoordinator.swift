import Foundation
import MFanControlShared
#if canImport(AppKit)
import AppKit
#endif

public protocol ExternalDisplaySource: Sendable {
    func hasExternalDisplay() -> Bool
}

public struct NSScreenDisplaySource: ExternalDisplaySource {
    public init() {}

    public func hasExternalDisplay() -> Bool {
        #if canImport(AppKit)
        return NSScreen.screens.count > 1
        #else
        return false
        #endif
    }
}

public final class AppCoordinator {
    public private(set) var state: ControlState = .idle
    public private(set) var stateSource: ControlSource = .appleDefault
    public private(set) var mode: ThermalPolicy.Mode = .balanced
    public private(set) var latestScore: ThermalScore = .init(value: 0)
    public private(set) var activeRPM: Int = 0
    public private(set) var latestSample: SensorSample?
    public private(set) var lastCommand: ControlCommand?
    public private(set) var hardwareProfile: HardwareProfile = HardwareDiscovery.detect()
    public private(set) var loggingEnabled: Bool = false

    private var stateMachine: ControlStateMachine
    private let engine: ThermalEngine
    private var scorer: ThermalScoringEngine
    private let xpc: any FanControlServiceProtocol
    private var appBoostUntil: Date = .distantPast
    private var manualBoostRequested = false
    private var previousScore: Double?
    private var lastDecision = "init"
    private var lastApplyAt: Date = .distantPast
    private var lastHardwareRefreshAt: Date = .distantPast
    private var lastRapidRiseSample: (temp: Double, at: Date)?
    private let minApplyInterval: TimeInterval = 3.0
    private let hardwareRefreshInterval: TimeInterval = 60.0
    private let rapidRiseTemperatureDelta: Double = 7.0
    private let rapidRiseWindowSec: TimeInterval = 4.0
    private let runningProcessScanner: any RunningProcessSource
    private let externalDisplayScanner: any ExternalDisplaySource

    public init(
        xpc: any FanControlServiceProtocol = XPCClient(),
        engine: ThermalEngine = .init(),
        scorer: ThermalScoringEngine = .init(),
        runningProcessScanner: any RunningProcessSource = WorkspaceProcessScanner(),
        externalDisplayScanner: any ExternalDisplaySource = NSScreenDisplaySource()
    ) {
        self.engine = engine
        self.scorer = scorer
        self.xpc = xpc
        self.stateMachine = ControlStateMachine()
        self.runningProcessScanner = runningProcessScanner
        self.externalDisplayScanner = externalDisplayScanner
    }

    public func start() {
        let persistedMode = ThermalPolicy.Mode(rawValue: exportConfig().profile)
        if let persistedMode {
            mode = persistedMode
            stateMachine.setMode(persistedMode)
        }
        syncScoringEngineFromConfig()
        hardwareProfile = xpc.discoverHardwareProfile()
        _ = stateMachine.apply(event: .discovered, hardwareProfile: hardwareProfile)
        state = stateMachine.state
        stateSource = stateMachine.source
        activeRPM = xpc.currentState().currentRPM
    }

    public func currentStateSnapshot() -> FanControlSnapshot {
        xpc.currentState()
    }

    public func currentProfileName() -> String {
        mode.rawValue
    }

    public func latestDisplayTempC() -> Double {
        latestSample?.hottestTemperatureReading()?.valueC ?? 0
    }

    public func latestSensorReadings(availability: [String: SensorChannelAvailability] = [:]) -> [SensorDisplayReading] {
        latestSample?.temperatureReadings(availability: availability) ?? SensorSample(timestamp: Date()).temperatureReadings(availability: availability)
    }

    public func canControl() -> Bool {
        hardwareProfile.hasFans && hardwareProfile.fans.contains(where: { $0.controllable })
    }

    public func stop() {
        _ = xpc.restoreToAppleDefault(reason: "user-stop")
        _ = stateMachine.apply(event: .manualDefault)
        state = .manualDefault
        stateSource = .userManual
    }

    public func toggleLogging() {
        loggingEnabled.toggle()
        MFanLogger.isEnabled = loggingEnabled
        (xpc as? XPCClient)?.setLoggingEnabled(loggingEnabled)
    }

    public func setMode(_ newMode: ThermalPolicy.Mode) {
        let result = xpc.setMode(newMode)
        if result.success {
            mode = newMode
            stateMachine.setMode(newMode)

            _ = evaluate()
            return
        }
        lastCommand = ControlCommand(action: .setProfile, targetRPM: 0, reason: "set-mode-failed: \(result.reason)")
        syncRuntimeState(from: xpc.currentState())
    }

    public func currentWhiteList() -> [String] {
        exportConfig().whiteList
    }

    public func replaceWhiteList(_ entries: [String]) -> FanControlResult {
        var config = exportConfig()
        config.whiteList = entries
        return importConfig(config)
    }

    public func addToWhiteList(_ entries: [String]) -> FanControlResult {
        var config = exportConfig()
        config.whiteList.append(contentsOf: entries)
        return importConfig(config)
    }

    public func removeFromWhiteList(_ entries: [String]) -> FanControlResult {
        let removalSet = Set(entries.map(ProcessIdentityMatcher.normalizedName))
        var config = exportConfig()
        config.whiteList = config.whiteList.filter {
            !removalSet.contains(ProcessIdentityMatcher.normalizedName($0))
        }
        return importConfig(config)
    }

    public func reportBoostTrigger(_ processNames: [String]) {
        let whitelist = Set(exportConfig().whiteList.map(ProcessIdentityMatcher.normalizedName))
        let matched = processNames.contains { process in
            let normalizedProcess = ProcessIdentityMatcher.normalizedName(process)
            return whitelist.contains(where: { normalizedProcess.contains($0) || $0.contains(normalizedProcess) })
        }
        if matched {
            appBoostUntil = Date().addingTimeInterval(20 * 60)
            manualBoostRequested = true
            _ = stateMachine.apply(event: .appBoostStart)
        } else if appBoostUntil != .distantPast {
            manualBoostRequested = false
            _ = stateMachine.apply(event: .appBoostStop)
            appBoostUntil = .distantPast
        }
    }

    public func evaluate() -> ControlCommand {
        let sample = xpc.readSensorSample()
        latestSample = sample
        let snapshotBeforeBoost = xpc.currentState()
        if let runtimeMode = ThermalPolicy.Mode(rawValue: snapshotBeforeBoost.activeProfile), runtimeMode != mode {
            mode = runtimeMode
            stateMachine.setMode(runtimeMode)
        }
        syncRuntimeState(from: snapshotBeforeBoost)
        var snapshot = snapshotBeforeBoost
        if [.safetyFallback].contains(snapshotBeforeBoost.state) {
            let command = ControlCommand(action: .restoreDefault, targetRPM: 0, reason: "safety-fallback")
            lastCommand = command
            return command
        }

        if [.manualDefault, .idle].contains(snapshotBeforeBoost.state) {
            let command = ControlCommand(
                action: .restoreDefault,
                targetRPM: 0,
                reason: snapshotBeforeBoost.state == .manualDefault ? "manual-default" : "no-auto-control"
            )
            lastCommand = command
            return command
        }

        if !(snapshotBeforeBoost.hardwareProfile?.hasFans ?? false) {
            let command = ControlCommand(action: .restoreDefault, targetRPM: 0, reason: "hardware-not-controllable")
            lastCommand = command
            return command
        }

        refreshAppBoostState()

        let score = scorer.compute(sample, previousScore: previousScore)
        previousScore = score.value
        latestScore = score
        let config = exportConfig()

        // Refresh hardware profile at most once per minute — hardware never changes at runtime
        let now2 = Date()
        if now2.timeIntervalSince(lastHardwareRefreshAt) >= hardwareRefreshInterval {
            hardwareProfile = xpc.discoverHardwareProfile()
            lastHardwareRefreshAt = now2
        }
        let discoveredProfile = hardwareProfile
        _ = stateMachine.apply(event: .discovered, hardwareProfile: discoveredProfile)
        state = stateMachine.state
        stateSource = stateMachine.source
        activeRPM = snapshotBeforeBoost.currentRPM
        snapshot = snapshotBeforeBoost

        if state == .idle || state == .safetyFallback {
            return ControlCommand(action: .restoreDefault, targetRPM: 0, reason: "no-control")
        }

        let appBoostActive = Date() <= appBoostUntil
        let hasExternalDisplay = externalDisplayScanner.hasExternalDisplay()
        let fanCap = discoveredProfile.fans.first
        let minRPM = fanCap?.minRPM ?? 1200
        let maxRPM = fanCap?.maxRPM ?? 6200
        let baseRampStep = mode == .performance ? 900 : (mode == .quiet ? 250 : 500)
        let constraints = (min: minRPM, max: maxRPM, rampStep: baseRampStep)
        let cmd = engine.buildPolicy(
            from: mode,
            score: score,
            appBoostActive: appBoostActive,
            currentRPM: activeRPM,
            constraints: constraints,
            onBattery: snapshot.powerSource.lowercased().contains("battery"),
            externalDisplay: hasExternalDisplay,
            customCurve: mode == .customCurve ? config.customCurve : nil,
            upgradeConservativeMode: config.upgradeConservativeMode
        )
        let policyMaxRPM = ThermalPolicy.defaults(for: mode).targetMaxRPM
        let adjustedCmd = applyRapidHeatSafety(cmd: cmd, sample: sample, hardwareMaxRPM: maxRPM, policyMaxRPM: policyMaxRPM)
        if shouldPauseControl(using: snapshot, sample: sample) {
            lastDecision = "state=\(state.rawValue);safety-pause"
            _ = xpc.restoreToAppleDefault(reason: "sensor-critical")
            let command = ControlCommand(action: .restoreDefault, targetRPM: 0, reason: "sensor-critical")
            lastCommand = command
            return command
        }
        lastDecision = decisionReason(
            mode: mode,
            score: score,
            appBoostActive: appBoostActive,
            externalDisplay: hasExternalDisplay,
            batteryState: snapshot.powerSource,
            sample: sample,
            throttle: snapshot.throttleState,
            conservativeMode: config.upgradeConservativeMode
        )
        let now = Date()
        if now.timeIntervalSince(lastApplyAt) < minApplyInterval {
            let command = ControlCommand(action: .refreshThrottle, targetRPM: adjustedCmd.targetRPM, reason: "command-throttled")
            lastCommand = command
            return command
        }

        lastApplyAt = now
        let applyResult = xpc.apply(adjustedCmd)
        syncRuntimeState(from: xpc.currentState())
        if applyResult.success {
            activeRPM = xpc.currentState().currentRPM
            lastCommand = adjustedCmd
            return adjustedCmd
        }

        let failedCommand = ControlCommand(
            action: adjustedCmd.action,
            targetRPM: adjustedCmd.targetRPM,
            minRPM: adjustedCmd.minRPM,
            maxRPM: adjustedCmd.maxRPM,
            rampStep: adjustedCmd.rampStep,
            reason: "apply-failed: \(applyResult.reason)"
        )
        lastCommand = failedCommand
        syncRuntimeState(from: xpc.currentState())
        return failedCommand
    }

    public func exportConfig() -> ThermalControlConfig {
        xpc.exportConfig()
    }

    public func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        let result = xpc.importConfig(config)
        if result.success {
            syncScoringEngineFromConfig()
        }
        return result
    }

    public func handleSystemWake() {
        _ = xpc.handleSystemWake()
        syncRuntimeState(from: xpc.currentState())
    }

    public func handleSystemSleep() {
        _ = xpc.handleSystemSleep()
        syncRuntimeState(from: xpc.currentState())
    }

    public func currentDecisionReason() -> String {
        lastDecision
    }

    public func recentTelemetrySamples(limit: Int = 8) -> [TelemetrySampleRecord] {
        xpc.recentSamples(limit: limit)
    }

    public func recentTelemetryEvents(limit: Int = 4) -> [TelemetryEventRecord] {
        xpc.recentEvents(limit: limit)
    }

    private func syncRuntimeState(from snapshot: FanControlSnapshot) {
        stateMachine.state = snapshot.state
        stateMachine.source = snapshot.source
        stateMachine.isControllable = snapshot.hardwareProfile?.fans.contains(where: { $0.controllable }) ?? false
        if let profile = snapshot.hardwareProfile {
            hardwareProfile = profile
        }
        state = snapshot.state
        stateSource = snapshot.source
        activeRPM = snapshot.currentRPM
        if let score = snapshot.thermalScore {
            latestScore = ThermalScore(value: score)
        }
    }

    private func syncScoringEngineFromConfig() {
        let config = exportConfig()
        scorer = ThermalScoringEngine(
            weights: config.weights,
            sustainedWindowSec: max(1, config.safetyThresholds.sustainedSeconds),
            sampleIntervalSec: max(0.5, config.safetyThresholds.sampleIntervalSec),
            smoothingFactor: 0.3
        )
    }

    private func applyRapidHeatSafety(cmd: ControlCommand, sample: SensorSample, hardwareMaxRPM: Int, policyMaxRPM: Int) -> ControlCommand {
        var adjusted = cmd
        let baseReason = adjusted.reason ?? "policy"
        let hottest = [sample.cpuPcoreTempC, sample.cpuEcoreTempC, sample.gpuTempC, sample.socTempC, sample.ssdTempC, sample.batteryTempC, sample.memoryTempC].compactMap { $0 }.max() ?? 0
        let now = sample.timestamp
        // Use policyMaxRPM for non-critical cases so quiet/balanced modes are not
        // pushed beyond their declared ceiling by transient temperature spikes.
        // Only genuine critical overheating (≥90°C) bypasses the policy cap.
        if let previous = lastRapidRiseSample,
            let interval = now.timeIntervalSince(previous.at) >= 0 ? now.timeIntervalSince(previous.at) : nil,
            interval <= rapidRiseWindowSec,
            hottest - previous.temp >= rapidRiseTemperatureDelta
        {
            let riseTarget = max(adjusted.targetRPM, Int(Double(policyMaxRPM) * 0.72))
            adjusted.targetRPM = min(policyMaxRPM, riseTarget)
            adjusted.rampStep = max(adjusted.rampStep ?? 300, 600)
            adjusted.reason = "\(baseReason);heat-emergency:rapid-rise"
        }
        if hottest >= 90 {
            adjusted.targetRPM = hardwareMaxRPM
            adjusted.rampStep = max(adjusted.rampStep ?? 300, 900)
            adjusted.reason = "\(baseReason);heat-emergency:max"
        } else if hottest >= 84 {
            let urgentTarget = max(adjusted.targetRPM, Int(Double(policyMaxRPM) * 0.85))
            adjusted.targetRPM = min(policyMaxRPM, urgentTarget)
            adjusted.rampStep = max(adjusted.rampStep ?? 300, 700)
            adjusted.reason = "\(baseReason);heat-emergency:high"
        } else if hottest >= 78 {
            let aheadTarget = max(adjusted.targetRPM, Int(Double(policyMaxRPM) * 0.72))
            adjusted.targetRPM = min(policyMaxRPM, aheadTarget)
            adjusted.rampStep = max(adjusted.rampStep ?? 300, 500)
            adjusted.reason = "\(baseReason);heat-emergency:pre"
        }
        if hottest > 0 {
            lastRapidRiseSample = (temp: hottest, at: now)
        } else {
            lastRapidRiseSample = nil
        }
        return adjusted
    }

    private func shouldPauseControl(using snapshot: FanControlSnapshot, sample: SensorSample) -> Bool {
        if snapshot.throttleState.isThrottling {
            return true
        }

        let critical = [SensorReadingSources.cpu, SensorReadingSources.gpu, SensorReadingSources.soc]
        let availabilityCount = critical.filter { snapshot.sensorAvailability[$0]?.available == true }.count
        if availabilityCount >= 2 {
            return false
        }

        let directCount = [sample.cpuPcoreTempC, sample.cpuEcoreTempC, sample.gpuTempC, sample.socTempC]
            .compactMap { $0 }
            .filter { $0 > 15 && $0 < 130 }
            .count

        if directCount >= 2 {
            return false
        }

        let rawCount = sample.rawTemperatureSensors.filter { (15...130).contains($0.tempC) }.count
        return directCount == 0 && rawCount < 2
    }

    private func refreshAppBoostState() {
        let running = Set(runningProcessScanner.runningProcesses().map { $0.lowercased() })
        let whitelist = Set(exportConfig().whiteList.map(ProcessIdentityMatcher.normalizedName))
        let now = Date()
        let matched = running.contains { process in
            let normalizedProcess = ProcessIdentityMatcher.normalizedName(process)
            return whitelist.contains { entry in
                normalizedProcess.contains(entry) || entry.contains(normalizedProcess)
            }
        }
        if Date() > appBoostUntil && manualBoostRequested {
            manualBoostRequested = false
        }
        if matched {
            let shouldExtend = appBoostUntil == .distantPast || Date() >= appBoostUntil || appBoostUntil.timeIntervalSinceNow <= 60 * 10
            if shouldExtend {
                appBoostUntil = now.addingTimeInterval(20 * 60)
                manualBoostRequested = false
                _ = stateMachine.apply(event: .appBoostStart)
            }
        } else if appBoostUntil != .distantPast {
            if !manualBoostRequested {
                appBoostUntil = .distantPast
                _ = stateMachine.apply(event: .appBoostStop)
            }
        }
    }

    private func decisionReason(
        mode: ThermalPolicy.Mode,
        score: ThermalScore,
        appBoostActive: Bool,
        externalDisplay: Bool,
        batteryState: String,
            sample: SensorSample,
            throttle: ThermalThrottleState,
            conservativeMode: Bool
    ) -> String {
        let temps = [
            ("cpu", sample.cpuPcoreTempC),
            ("gpu", sample.gpuTempC),
            ("soc", sample.socTempC),
            ("ssd", sample.ssdTempC),
            ("battery", sample.batteryTempC),
            ("mem", sample.memoryTempC)
        ].compactMap { pair -> String? in
            guard let value = pair.1 else { return nil }
            return "\(pair.0):\(Int(value))"
        }
        let topTemps = temps.joined(separator: ",")
        return [
            "mode=\(mode.rawValue)",
            "score=\(Int(score.value))",
            "band=\(score.band.rawValue)",
            "appBoost=\(appBoostActive)",
            "conservative=\(conservativeMode)",
            "external=\(externalDisplay)",
            "battery=\(batteryState)",
            "throttling=\(throttle.isThrottling)",
            "temps=\(topTemps)"
        ].joined(separator: ";")
    }
}

public protocol RunningProcessSource: Sendable {
    func runningProcesses() -> [String]
}

public struct WorkspaceProcessScanner: RunningProcessSource {
    public init() {}

    public func runningProcesses() -> [String] {
        #if canImport(AppKit)
        NSWorkspace.shared.runningApplications.compactMap { $0.localizedName }
        #else
        []
        #endif
    }
}
