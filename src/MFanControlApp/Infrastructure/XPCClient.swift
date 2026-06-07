import Foundation
import MFanControlShared
import MFanControlHelperCore

public final class XPCClient: FanControlServiceProtocol {
    private let host = XPCHost()

    public init() {
        host.start()
    }

    public func currentState() -> FanControlSnapshot {
        return awaitValue(host.currentState())
    }

    public func apply(_ command: ControlCommand) -> FanControlResult {
        return awaitValue(host.apply(command))
    }

    public func restoreToAppleDefault(reason: String) -> FanControlResult {
        return awaitValue(host.restoreToAppleDefault(reason: reason))
    }

    public func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        return awaitValue(host.setMode(mode))
    }

    public func discoverHardwareProfile() -> HardwareProfile {
        return awaitValue(host.discoverHardwareProfile())
    }

    public func readSensorSample() -> SensorSample {
        return awaitValue(host.readSensorSample())
    }

    public func exportConfig() -> ThermalControlConfig {
        return awaitValue(host.exportConfig())
    }

    public func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        return awaitValue(host.importConfig(config))
    }

    public func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        awaitValue(host.recentSamples(limit: limit))
    }

    public func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        awaitValue(host.recentEvents(limit: limit))
    }

    public func resetForUninstall() -> FanControlResult {
        awaitValue(host.resetForUninstall())
    }

    public func handleSystemWake() -> FanControlResult {
        awaitValue(host.systemWake())
    }

    public func handleSystemSleep() -> FanControlResult {
        awaitValue(host.systemSleep())
    }

    public func systemWake() -> FanControlResult {
        awaitValue(host.systemWake())
    }

    public func systemSleep() -> FanControlResult {
        awaitValue(host.systemSleep())
    }

    public func send(_ command: ControlCommand) {
        _ = apply(command)
    }

    private func awaitValue<T>(_ body: @autoclosure () -> T) -> T { body() }
}

public extension XPCClient {
    func currentStateSnapshotMessage() -> String? {
        let snapshot = currentState()
        guard snapshot.state == .safetyFallback else { return nil }
        return snapshot.reason
    }
}
