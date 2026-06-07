import XCTest
import MFanControlShared
import MFanControlHelperCore

final class FanControlDaemonFailureTests: XCTestCase {
    private func makeProfile() -> HardwareProfile {
        HardwareProfile(
            chip: "Apple M3",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(
                fanCount: 1,
                minRPM: 1200,
                maxRPM: 6200,
                modelIdentifier: "F0",
                controllable: true
            )]
        )
    }

    private func makeRuntimeService(profile: HardwareProfile) -> FanControlRuntimeService {
        FanControlRuntimeService(
            configuration: ThermalControlConfig(profile: "balanced"),
            hardwareProfile: profile,
            sensorSampler: DeterministicSensorSampler(),
            telemetryStore: InMemoryTelemetryStore(),
            configStore: ConfigStore(suiteName: "com.fancontrol.tests.integration.daemon-fallback-\(UUID().uuidString)")
        )
    }

    func testApplyCommandWithUnavailableSMCFallsBackToSafetyMode() {
        let service = makeRuntimeService(profile: makeProfile())
        let daemon = FanControlDaemon(
            service: service,
            forceSMCUnavailable: true
        )
        _ = service.readSensorSample()
        let result = daemon.applyCommand(ControlCommand(action: .setProfile, targetRPM: 2800))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .hardwareUnreachable)
        XCTAssertEqual(result.state, .safetyFallback)
        XCTAssertEqual(result.source, .safetyMode)
        XCTAssertEqual(result.reason, "smc-command-unavailable")
    }

    func testApplyCommandWithFailingSMCWriteFallsBackToSafetyMode() {
        let service = makeRuntimeService(profile: makeProfile())
        let daemon = FanControlDaemon(
            service: service,
            forceSMCWriteFailure: true
        )
        _ = service.readSensorSample()
        let result = daemon.applyCommand(ControlCommand(action: .applyPolicy, targetRPM: 2800))

        XCTAssertFalse(result.success)
        XCTAssertEqual(result.failure, .hardwareUnreachable)
        XCTAssertEqual(result.state, .safetyFallback)
        XCTAssertEqual(result.source, .safetyMode)
        XCTAssertTrue(result.reason.hasPrefix("smc-write-failed:"))
    }
}
