import XCTest
import MFanControlShared
@testable import MFanControlApp
import MFanControlHelperCore
#if canImport(AppKit)
import AppKit
#endif

private final class TestService: FanControlServiceProtocol {
    private let runtime: FanControlRuntimeService
    private let configStore: ConfigStore

    init(profile: HardwareProfile, config: ThermalControlConfig = ThermalControlConfig()) {
        let suiteName = "com.fancontrol.tests.integration.\(UUID().uuidString)"
        self.configStore = ConfigStore(suiteName: suiteName)
        self.runtime = FanControlRuntimeService(
            configuration: config,
            hardwareProfile: profile,
            sensorSampler: DeterministicSensorSampler(),
            telemetryStore: InMemoryTelemetryStore(),
            configStore: configStore
        )
    }

    func currentState() -> FanControlSnapshot {
        runtime.currentState()
    }

    func apply(_ command: ControlCommand) -> FanControlResult {
        runtime.apply(command)
    }

    func restoreToAppleDefault(reason: String) -> FanControlResult {
        runtime.restoreToAppleDefault(reason: reason)
    }

    func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        runtime.setMode(mode)
    }

    func discoverHardwareProfile() -> HardwareProfile {
        runtime.discoverHardwareProfile()
    }

    func readSensorSample() -> SensorSample {
        runtime.readSensorSample()
    }

    func exportConfig() -> ThermalControlConfig {
        runtime.exportConfig()
    }

    func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        runtime.importConfig(config)
    }

    func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        runtime.recentSamples(limit: limit)
    }

    func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        runtime.recentEvents(limit: limit)
    }

    func resetForUninstall() -> FanControlResult {
        runtime.resetForUninstall()
    }

    func handleSystemWake() -> FanControlResult {
        runtime.handleSystemWake()
    }

    func handleSystemSleep() -> FanControlResult {
        runtime.handleSystemSleep()
    }
}

final class AppFlowTests: XCTestCase {
    private struct RunningProcessStub: RunningProcessSource {
        let names: [String]

        func runningProcesses() -> [String] {
            names
        }
    }

    private struct DisplaySourceStub: ExternalDisplaySource {
        let hasExternal: Bool

        func hasExternalDisplay() -> Bool {
            hasExternal
        }
    }

    private final class FakeControlService: FanControlServiceProtocol {
        private let profile: HardwareProfile
        private var currentRPM: Int
        private var targetRPM: Int
        private var activeMode: ThermalPolicy.Mode = .balanced
        private var state: ControlState = .smartControl
        private var source: ControlSource = .appAuto
        private let availability: [String: SensorChannelAvailability] = [
            SensorReadingSources.cpu: .init(available: true, confidence: 1),
            SensorReadingSources.gpu: .init(available: true, confidence: 1),
            SensorReadingSources.soc: .init(available: true, confidence: 1)
        ]
        private let throttleState = ThermalThrottleState(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "")

        init(profile: HardwareProfile, initialRPM: Int = 4880) {
            self.profile = profile
            self.currentRPM = initialRPM
            self.targetRPM = initialRPM
        }

        func currentState() -> FanControlSnapshot {
            FanControlSnapshot(
                state: state,
                source: source,
                hardwareProfile: profile,
                activeProfile: activeMode.rawValue,
                currentRPM: currentRPM,
                targetRPM: targetRPM,
                appBoostActive: false,
                thermalScore: 72,
                powerSource: "AC",
                throttleState: throttleState,
                sensorAvailability: availability,
                reason: "fake"
            )
        }

        func apply(_ command: ControlCommand) -> FanControlResult {
            currentRPM = command.targetRPM
            targetRPM = command.targetRPM
            state = .smartControl
            source = .appAuto
            return FanControlResult(
                success: true,
                reason: command.reason ?? "fake",
                state: state,
                source: source,
                timestamp: Date()
            )
        }

        func restoreToAppleDefault(reason: String) -> FanControlResult {
            currentRPM = profile.fans.first?.minRPM ?? 1200
            targetRPM = currentRPM
            state = .manualDefault
            source = .userManual
            return FanControlResult(success: true, reason: reason, state: state, source: source, timestamp: Date())
        }

        func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
            activeMode = mode
            return FanControlResult(success: true, reason: "setMode", state: state, source: source, timestamp: Date())
        }

        func discoverHardwareProfile() -> HardwareProfile {
            profile
        }

        func readSensorSample() -> SensorSample {
            SensorSample(
                timestamp: Date(),
                cpuPcoreTempC: 95,
                cpuEcoreTempC: 94,
                gpuTempC: 96,
                socTempC: 93,
                ssdTempC: 60,
                batteryTempC: 35,
                memoryTempC: 40,
                powerWatts: 40,
                sustainedLoadSec: 20
            )
        }

        func exportConfig() -> ThermalControlConfig {
            ThermalControlConfig()
        }

        func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
            FanControlResult(success: true, reason: "import", state: .smartControl, source: .appAuto, timestamp: Date())
        }

        func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
            []
        }

        func recentEvents(limit: Int) -> [TelemetryEventRecord] {
            []
        }

        func resetForUninstall() -> FanControlResult {
            state = .manualDefault
            source = .userManual
            return FanControlResult(success: true, reason: "reset", state: state, source: source, timestamp: Date())
        }

        func handleSystemWake() -> FanControlResult {
            state = .smartControl
            source = .appAuto
            return FanControlResult(success: true, reason: "system-wake", state: state, source: source, timestamp: Date())
        }

        func handleSystemSleep() -> FanControlResult {
            state = .manualDefault
            source = .userManual
            return FanControlResult(success: true, reason: "system-sleep", state: state, source: source, timestamp: Date())
        }
    }

    func testNoFanProfileCannotIssueControlCommands() {
        let noFanProfile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookAir",
            isAppleSilicon: true,
            hasFans: false,
            fans: []
        )
        let service = TestService(profile: noFanProfile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        XCTAssertEqual(service.currentState().reason, "hardware-not-controllable")
        let cmd = coordinator.evaluate()

        XCTAssertEqual(cmd.action, .restoreDefault)
    }

    func testManualDefaultHoldsAutoControlOff() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        coordinator.stop()

        let command = coordinator.evaluate()

        XCTAssertEqual(command.action, .restoreDefault)
        XCTAssertEqual(command.reason, "manual-default")
    }

    func testCoordinatorRecordsLatestSampleAndCommand() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()

        let command = coordinator.evaluate()

        XCTAssertNotNil(coordinator.latestSample)
        XCTAssertEqual(coordinator.lastCommand?.action, command.action)
        XCTAssertGreaterThan(coordinator.latestDisplayTempC(), 40)
        XCTAssertFalse(coordinator.currentProfileName().isEmpty)
        XCTAssertTrue(coordinator.canControl())
    }

    func testCoordinatorStartsWithPersistedProfileMode() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let config = ThermalControlConfig(profile: "performance")
        let service = TestService(profile: profile, config: config)
        let coordinator = AppCoordinator(xpc: service)

        coordinator.start()
        XCTAssertEqual(coordinator.currentProfileName(), "performance")
    }

    func testCoordinatorUsesCustomCurveFromConfig() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        var config = ThermalControlConfig(profile: "customCurve")
        config.customCurve = [
            .init(score: 0, rpm: 1800),
            .init(score: 90, rpm: 6200),
            .init(score: 100, rpm: 6200)
        ]

        func advance(_ coordinator: AppCoordinator, steps: Int) -> Int {
            var rpm = 0
            for _ in 0..<steps {
                rpm = coordinator.evaluate().targetRPM
            }
            return rpm
        }

        func makeCoordinator(for config: ThermalControlConfig) -> AppCoordinator {
            let service = TestService(profile: profile, config: config)
            let coordinator = AppCoordinator(xpc: service)
            coordinator.start()
            coordinator.setMode(config.profile == "customCurve" ? .customCurve : .balanced)
            return coordinator
        }

        let customCoordinator = makeCoordinator(for: config)
        XCTAssertEqual(customCoordinator.currentProfileName(), "customCurve")
        let customRPM = advance(customCoordinator, steps: 12)

        let balancedConfig = ThermalControlConfig(profile: "balanced")
        let balancedCoordinator = makeCoordinator(for: balancedConfig)
        let balancedRPM = advance(balancedCoordinator, steps: 12)

        XCTAssertGreaterThan(customRPM, balancedRPM)
    }

    func testUpgradeConservativeModeReducesPolicyAggressivenessInFlow() {
        let profile = HardwareProfile(
            chip: "Apple M3",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )

        var normalConfig = ThermalControlConfig(profile: "performance")
        normalConfig.upgradeConservativeMode = false
        let normalService = TestService(profile: profile, config: normalConfig)
        let normalCoordinator = AppCoordinator(
            xpc: normalService,
            runningProcessScanner: RunningProcessStub(names: []),
            externalDisplayScanner: DisplaySourceStub(hasExternal: false)
        )
        normalCoordinator.start()
        normalCoordinator.setMode(.performance)
        let normalCommand = normalCoordinator.evaluate()

        var conservativeConfig = ThermalControlConfig(profile: "performance")
        conservativeConfig.upgradeConservativeMode = true
        let conservativeService = TestService(profile: profile, config: conservativeConfig)
        let conservativeCoordinator = AppCoordinator(
            xpc: conservativeService,
            runningProcessScanner: RunningProcessStub(names: []),
            externalDisplayScanner: DisplaySourceStub(hasExternal: false)
        )
        conservativeCoordinator.start()
        conservativeCoordinator.setMode(.performance)
        let conservativeCommand = conservativeCoordinator.evaluate()

        XCTAssertLessThanOrEqual(conservativeCommand.targetRPM, normalCommand.targetRPM)
        XCTAssertTrue(conservativeCoordinator.currentDecisionReason().contains("conservative=true"))
    }

    func testAppBoostAffectsDecisionReason() {
        let fanProfile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: fanProfile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        coordinator.setMode(.balanced)
        coordinator.reportBoostTrigger(["Xcode"])
        _ = coordinator.evaluate()

        XCTAssertTrue(coordinator.currentDecisionReason().contains("appBoost=true"))
    }

    func testCoordinatorWhiteListCanBeEditedAndTakesEffect() {
        let fanProfile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: fanProfile)
        let coordinator = AppCoordinator(
            xpc: service,
            runningProcessScanner: RunningProcessStub(names: ["CustomBuild"])
        )
        coordinator.start()

        let addResult = coordinator.addToWhiteList(["CustomBuild"])
        XCTAssertTrue(addResult.success)
        _ = coordinator.evaluate()
        XCTAssertTrue(coordinator.currentDecisionReason().contains("appBoost=true"))

        let removeResult = coordinator.removeFromWhiteList(["CustomBuild"])
        XCTAssertTrue(removeResult.success)
        _ = coordinator.evaluate()
        XCTAssertFalse(coordinator.currentDecisionReason().contains("appBoost=true"))
    }

    func testImportConfigRoundTripInFlow() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()

        var config = coordinator.exportConfig()
        config.profile = "performance"
        let result = coordinator.importConfig(config)

        XCTAssertTrue(result.success)
        XCTAssertEqual(coordinator.exportConfig().profile, "performance")
    }

    func testAutoBoostFromRunningProcesses() {
        let profile = HardwareProfile(
            chip: "Apple M3",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = TestService(profile: profile)
        let coordinator = AppCoordinator(
            xpc: service,
            runningProcessScanner: RunningProcessStub(names: ["Xcode"])
        )
        coordinator.start()
        coordinator.setMode(.balanced)
        let command = coordinator.evaluate()

        XCTAssertTrue(command.targetRPM >= 1200)
        XCTAssertTrue(coordinator.currentDecisionReason().contains("appBoost=true"))
    }

    func testXPCRemoteUnavailableFallsBackToLocalRuntime() {
        let host = XPCHost(mode: .remoteOnly, serviceName: "com.starrysky.MFanControlHelper.xpc.missing")
        host.start()

        let snapshot = host.currentState()
        let baseline = FanControlRuntimeService.shared.currentState()

        XCTAssertNotNil(snapshot.hardwareProfile)
        XCTAssertEqual(snapshot.state, baseline.state)
        XCTAssertEqual(snapshot.currentRPM, baseline.currentRPM)

        let command = ControlCommand(action: .setProfile, targetRPM: 1800)
        let result = host.apply(command)
        let expected = FanControlRuntimeService.shared.apply(command)

        XCTAssertEqual(result.success, expected.success)
        XCTAssertEqual(result.reason, expected.reason)
        XCTAssertEqual(result.state, expected.state)
        XCTAssertEqual(result.failure, expected.failure)
        XCTAssertEqual(result.source, expected.source)

        let postState = FanControlRuntimeService.shared.currentState()
        XCTAssertEqual(postState.hardwareProfile?.deviceModel, snapshot.hardwareProfile?.deviceModel)
    }

    func testExternalDisplayAcceleratesPolicyCommand() {
        let profile = HardwareProfile(
            chip: "Apple M3",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )

        let serviceNoDisplay = FakeControlService(profile: profile)
        let coordinatorNoDisplay = AppCoordinator(
            xpc: serviceNoDisplay,
            runningProcessScanner: RunningProcessStub(names: []),
            externalDisplayScanner: DisplaySourceStub(hasExternal: false)
        )
        coordinatorNoDisplay.start()
        let commandNoDisplay = coordinatorNoDisplay.evaluate()

        let serviceWithDisplay = FakeControlService(profile: profile)
        let coordinatorWithDisplay = AppCoordinator(
            xpc: serviceWithDisplay,
            runningProcessScanner: RunningProcessStub(names: []),
            externalDisplayScanner: DisplaySourceStub(hasExternal: true)
        )
        coordinatorWithDisplay.start()
        let commandWithDisplay = coordinatorWithDisplay.evaluate()

        XCTAssertTrue(coordinatorWithDisplay.currentDecisionReason().contains("external=true"))
        XCTAssertTrue(commandWithDisplay.targetRPM >= commandNoDisplay.targetRPM)
        if commandWithDisplay.targetRPM == commandNoDisplay.targetRPM {
            XCTAssertTrue(commandWithDisplay.rampStep ?? 0 >= 500)
        } else {
            XCTAssertTrue(commandWithDisplay.targetRPM > commandNoDisplay.targetRPM)
        }
    }

    func testSystemWakeTransitionsCoordinatorFromManualDefaultToControlPath() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FakeControlService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        coordinator.stop()
        XCTAssertEqual(coordinator.state, .manualDefault)

        coordinator.handleSystemWake()
        XCTAssertEqual(coordinator.state, .smartControl)
        let command = coordinator.evaluate()
        XCTAssertEqual(command.action, .setProfile)
    }

    func testSystemSleepTransitionsCoordinatorToManualDefault() {
        let profile = HardwareProfile(
            chip: "Apple M3",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FakeControlService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        coordinator.handleSystemSleep()
        XCTAssertEqual(coordinator.state, .manualDefault)

        let command = coordinator.evaluate()
        XCTAssertEqual(command.action, .restoreDefault)
        XCTAssertEqual(command.reason, "manual-default")
    }

    func testLifecycleLoopForwardsSystemSleepAndWakeNotifications() {
        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FakeControlService(profile: profile)
        let coordinator = AppCoordinator(xpc: service)
        coordinator.start()
        let loop = AppLifecycleLoop(coordinator: coordinator)
        loop.start(runLoop: false)
        defer { loop.stop() }

        coordinator.stop()
        XCTAssertEqual(coordinator.state, .manualDefault)

        #if canImport(AppKit)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        XCTAssertEqual(coordinator.state, .manualDefault)

        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(coordinator.state, .smartControl)
        #else
        XCTFail("AppKit unavailable: cannot validate wake/sleep notifications")
        #endif
    }
}
