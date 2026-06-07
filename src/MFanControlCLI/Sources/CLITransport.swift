import Foundation
import MFanControlShared
import MFanControlHelperCore

final class XPCClient: FanControlServiceProtocol {
    private let host = XPCHost()

    init() {
        host.start()
    }

    func currentState() -> FanControlSnapshot {
        host.currentState()
    }

    func apply(_ command: ControlCommand) -> FanControlResult {
        host.apply(command)
    }

    func restoreToAppleDefault(reason: String) -> FanControlResult {
        host.restoreToAppleDefault(reason: reason)
    }

    func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        host.setMode(mode)
    }

    func discoverHardwareProfile() -> HardwareProfile {
        host.discoverHardwareProfile()
    }

    func readSensorSample() -> SensorSample {
        host.readSensorSample()
    }

    func exportConfig() -> ThermalControlConfig {
        host.exportConfig()
    }

    func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        host.importConfig(config)
    }

    func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        host.recentSamples(limit: limit)
    }

    func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        host.recentEvents(limit: limit)
    }

    func resetForUninstall() -> FanControlResult {
        host.resetForUninstall()
    }

    func handleSystemWake() -> FanControlResult {
        host.systemWake()
    }

    func handleSystemSleep() -> FanControlResult {
        host.systemSleep()
    }
}
