import Foundation
import MFanControlShared

public final class FanControlDaemon {
    public static let shared = FanControlDaemon()

    private let bridge: SMCBridging
    private let service: FanControlRuntimeService

    public init(service: FanControlRuntimeService = .shared, forceSMCUnavailable: Bool = false, forceSMCWriteFailure: Bool = false) {
        self.service = service

        if forceSMCWriteFailure {
            self.bridge = FailingSMCBridge()
            return
        }

        if forceSMCUnavailable {
            self.bridge = UnavailableSMCBridge()
            return
        }

        if ProcessInfo.processInfo.environment["MFANCONTROL_FORCE_PLACEHOLDER_SMC"] == "1" {
            self.bridge = PlaceholderSMCBridge()
        }
        else {
            self.bridge = SystemSMCBridge()
        }
    }

    private final class UnavailableSMCBridge: SMCBridging {
        var isAvailable: Bool { false }

        func readSensor(_ key: String) throws -> Double? {
            throw SMCBridgeError.commandFailure("forced-smc-unavailable")
        }

        func writeFanRPM(_ fanKey: String, rpm: Int) throws -> Bool {
            throw SMCBridgeError.commandFailure("forced-smc-unavailable")
        }

        func currentFanRPM(fanKey: String) throws -> Int {
            throw SMCBridgeError.commandFailure("forced-smc-unavailable")
        }
    }

    private final class FailingSMCBridge: SMCBridging {
        var isAvailable: Bool { true }

        func readSensor(_ key: String) throws -> Double? {
            throw SMCBridgeError.commandFailure("forced-smc-write-failure")
        }

        func writeFanRPM(_ fanKey: String, rpm: Int) throws -> Bool {
            throw SMCBridgeError.commandFailure("forced-smc-write-failure")
        }

        func currentFanRPM(fanKey: String) throws -> Int {
            throw SMCBridgeError.commandFailure("forced-smc-write-failure")
        }
    }

    public func start() {
        print("MFanControlHelper daemon start")
        print("smc-bridge: \(type(of: bridge))")
    }

    public func serviceSnapshot() -> FanControlSnapshot {
        snapshotWithObservedRPM(service.currentState())
    }

    public func readSensorSample() -> SensorSample {
        service.readSensorSample()
    }

    public func exportConfig() -> ThermalControlConfig {
        service.exportConfig()
    }

    public func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        service.importConfig(config)
    }

    public func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        service.recentSamples(limit: limit)
    }

    public func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        service.recentEvents(limit: limit)
    }

    public func resetForUninstall() -> FanControlResult {
        service.resetForUninstall()
    }

    public func handleSystemWake() -> FanControlResult {
        service.handleSystemWake()
    }

    public func handleSystemSleep() -> FanControlResult {
        service.handleSystemSleep()
    }

    public func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        service.setMode(mode)
    }

    public func restoreDefault(reason: String = "helper-default") -> FanControlResult {
        service.restoreToAppleDefault(reason: reason)
    }

    public func applyCommand(_ command: ControlCommand) -> FanControlResult {
        let result = service.apply(command)
        if !result.success {
            return result
        }

        guard command.action == .setProfile || command.action == .applyPolicy else {
            return result
        }

        guard bridge.isAvailable else {
            print("smc command unavailable: entering safety fallback before writing")
            return safetyFallbackResult(reason: "smc-command-unavailable")
        }

        print("fan-control apply received command=\(command.action.rawValue) targetRPM=\(command.targetRPM) source=\(result.source.rawValue) state=\(result.state.rawValue)")
        let controllable = service.currentState().hardwareProfile?.fans.filter { $0.controllable } ?? []
        do {
            guard !controllable.isEmpty else {
                return FanControlResult(
                    success: false,
                    reason: "hardware-not-controllable",
                    failure: .notAvailable,
                    state: result.state,
                    source: result.source,
                    timestamp: Date()
                )
            }
            let fanCount = max(1, controllable.first?.fanCount ?? 1)
            let rpmToWrite = service.currentState().currentRPM
            for fan in 0..<fanCount {
                let fanKey = SMCKeyCatalog.fanCurrentRPMKey(for: fan)
                _ = try bridge.writeFanRPM(fanKey, rpm: rpmToWrite)
                if let readbackRPM = try? bridge.currentFanRPM(fanKey: fanKey) {
                    let drift = abs(readbackRPM - rpmToWrite)
                    let driftTolerance = max(450, min(800, command.targetRPM / 4))
                    if drift > driftTolerance && rpmToWrite > 0 {
                        throw SMCBridgeError.commandFailure(
                            "fan-rpm-unchanged fan=\(fan) requested=\(rpmToWrite) readback=\(readbackRPM)"
                        )
                    }
                }
            }
        } catch {
            print("smc write failed for rpm=\(command.targetRPM): \(error)")
            return safetyFallbackResult(reason: "smc-write-failed:\(error)")
        }

        return result
    }

    private func safetyFallbackResult(reason: String) -> FanControlResult {
        let fallback = service.enterSafetyFallback(reason: reason)
        return FanControlResult(
            success: false,
            reason: fallback.reason,
            failure: .hardwareUnreachable,
            state: fallback.state,
            source: fallback.source,
            timestamp: Date()
        )
    }

    public func refreshFromHardwareProfile() {
        _ = service.discoverHardwareProfile()
    }

    public func recoverSafetyDefaults() {
        _ = service.restoreToAppleDefault(reason: "daemon-safety-recovery")
        service.setAppBoost(until: .distantPast)
    }

    public func discoverHardware() -> HardwareProfile {
        service.discoverHardwareProfile()
    }

    private func snapshotWithObservedRPM(_ snapshot: FanControlSnapshot) -> FanControlSnapshot {
        guard let profile = snapshot.hardwareProfile, profile.hasFans else {
            return snapshot
        }
        let controllableFans = profile.fans.filter { $0.controllable }
        guard !controllableFans.isEmpty else {
            return snapshot
        }
        let fanCount = max(1, controllableFans.first?.fanCount ?? 1)

        for fan in 0..<fanCount {
            let fanKey = SMCKeyCatalog.fanCurrentRPMKey(for: fan)
            if let readbackRPM = try? bridge.currentFanRPM(fanKey: fanKey), readbackRPM > 0 {
                var updated = snapshot
                updated.currentRPM = readbackRPM
                return updated
            }
        }
        return snapshot
    }
}
