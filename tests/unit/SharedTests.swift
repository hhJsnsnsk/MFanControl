import XCTest
import MFanControlShared

private final class RetentionRecordingTelemetryStore: TelemetryStoreProtocol {
    private(set) var lastConfiguredHistory = HistoryRetention()
    private(set) var lastConfiguredDebounce = 15.0

    func append(_ record: TelemetrySampleRecord) {}

    func fetchRecent(limit: Int) -> [TelemetrySampleRecord] {
        []
    }

    func appendEvent(_ event: TelemetryEventRecord) {}

    func fetchRecentEvents(limit: Int) -> [TelemetryEventRecord] {
        []
    }

    func clear() {}

    func reconfigureRetention(historyRetention: HistoryRetention, eventDebounceMinutes: Double) {
        lastConfiguredHistory = historyRetention
        lastConfiguredDebounce = eventDebounceMinutes
    }
}

final class SharedTests: XCTestCase {
    func testHardwareDiscoveryRespectsChipAndModelOverrides() {
        setenv("MFANCONTROL_CHIP", "Apple M4 Pro", 1)
        setenv("MFANCONTROL_MODEL", "MacBookAir10,1", 1)
        defer {
            unsetenv("MFANCONTROL_CHIP")
            unsetenv("MFANCONTROL_MODEL")
        }

        let air = HardwareDiscovery.detect()
        XCTAssertEqual(air.chip, "Apple M4 Pro")
        XCTAssertTrue(air.isAppleSilicon)
        XCTAssertFalse(air.hasFans)
        XCTAssertEqual(air.fans.count, 0)

        setenv("MFANCONTROL_MODEL", "Mac14,9", 1)
        let air2 = HardwareDiscovery.detect()
        XCTAssertEqual(air2.hasFans, true)
        XCTAssertEqual(air2.fans.count, 1)
        XCTAssertTrue(air2.fans.allSatisfy { $0.controllable })

        setenv("MFANCONTROL_CHIP", "Apple M5", 1)
        let m5 = HardwareDiscovery.detect()
        XCTAssertEqual(m5.fans.first?.fanCount, 1)
    }

    func testHardwareDiscoveryHandlesUnsupportedIntelAsNonControllable() {
        setenv("MFANCONTROL_CHIP", "Intel Xeon", 1)
        setenv("MFANCONTROL_MODEL", "MacBookPro16,1", 1)
        defer {
            unsetenv("MFANCONTROL_CHIP")
            unsetenv("MFANCONTROL_MODEL")
        }

        let profile = HardwareDiscovery.detect()
        XCTAssertFalse(profile.isAppleSilicon)
        XCTAssertEqual(profile.hasFans, false)
        XCTAssertEqual(profile.fans.count, 0)
        XCTAssertEqual(profile.deviceModel, "MacBookPro:MacBookPro16,1")
    }

    func testThermalScorerProducesSmoothMonotonicScores() {
        let engine = ThermalScoringEngine(weights: ThermalWeights(), sustainedWindowSec: 8, smoothingFactor: 0.4)
        let sample1 = SensorSample(
            timestamp: Date(),
            cpuPcoreTempC: 55,
            cpuEcoreTempC: 50,
            gpuTempC: 48,
            socTempC: 46,
            ssdTempC: 40,
            batteryTempC: 35,
            memoryTempC: 43,
            powerWatts: 15,
            sustainedLoadSec: 1
        )
        let score1 = engine.compute(sample1)

        let sample2 = SensorSample(
            timestamp: Date(),
            cpuPcoreTempC: 88,
            cpuEcoreTempC: 84,
            gpuTempC: 92,
            socTempC: 87,
            ssdTempC: 72,
            batteryTempC: 51,
            memoryTempC: 80,
            powerWatts: 56,
            sustainedLoadSec: 12
        )
        let score2 = engine.compute(sample2, previousScore: score1.value)

        XCTAssertGreaterThan(score2.value, score1.value)
        XCTAssertLessThanOrEqual(score2.value, 100)
        XCTAssertGreaterThanOrEqual(score2.value, 0)
    }

    func testThermalScoreBandClassification() {
        let score = ThermalScore(value: 85)
        XCTAssertEqual(score.band, .safety)
        XCTAssertEqual(score.clampedValue, 85)
    }

    func testSystemSensorSamplerDoesNotInventTemperaturesWhenSystemSourcesAreUnavailable() {
        let sampler = SystemSensorSampler(
            runShell: { _, _ in nil },
            rawTemperatureSensorSource: EmptyRawTemperatureSensorSource()
        )

        let output = sampler.nextSample(at: Date())
        let readings = output.sample.temperatureReadings(availability: output.availability)

        XCTAssertNil(output.sample.hottestTemperatureReading(availability: output.availability))
        XCTAssertTrue(readings.allSatisfy { !$0.available })
        XCTAssertEqual(output.availability[SensorReadingSources.cpu]?.available, false)
        XCTAssertEqual(output.availability[SensorReadingSources.gpu]?.available, false)
        XCTAssertEqual(output.availability[SensorReadingSources.soc]?.available, false)
    }

    func testSystemSensorSamplerConvertsMilliwattsToWatts() {
        let sampler = SystemSensorSampler(
            runShell: { _, arguments in
                if arguments.contains("powermetrics") {
                    return """
                    CPU Power: 8680 mW
                    GPU Power: 294 mW
                    """
                }
                return nil
            },
            rawTemperatureSensorSource: EmptyRawTemperatureSensorSource()
        )

        let output = sampler.nextSample(at: Date())

        XCTAssertEqual(output.sample.powerWatts ?? 0, 8.68, accuracy: 0.01)
        XCTAssertNil(output.sample.hottestTemperatureReading(availability: output.availability))
    }

    func testSystemSensorSamplerIncludesRawTemperatureSensors() {
        struct RawSourceStub: RawTemperatureSensorSource {
            func readRawTemperatureSensors() -> [RawTemperatureSensorReading] {
                [
                    RawTemperatureSensorReading(name: "PMU tdie1", tempC: 72.4),
                    RawTemperatureSensorReading(name: "NAND CH0 temp", tempC: 58.1)
                ]
            }
        }
        let sampler = SystemSensorSampler(
            runShell: { _, _ in nil },
            rawTemperatureSensorSource: RawSourceStub()
        )

        let output = sampler.nextSample(at: Date())
        let hottest = output.sample.hottestTemperatureReading(availability: output.availability)
        let readings = output.sample.temperatureReadings(availability: output.availability)
        let rawReadings = readings.filter { $0.id.hasPrefix("raw:") }

        XCTAssertEqual(output.sample.rawTemperatureSensors.count, 2)
        XCTAssertEqual(hottest?.valueC ?? 0, 72.4, accuracy: 0.01)
        XCTAssertTrue(rawReadings.contains { $0.label == "PMU DIE 1" && $0.available })
        XCTAssertTrue(readings.contains { $0.label == "NAND CH0" && $0.available })
    }

    func testSystemSensorSamplerKeepsCriticalSensorsUnavailableWhenPrimarySourcesMissing() {
        struct RawSourceStub: RawTemperatureSensorSource {
            func readRawTemperatureSensors() -> [RawTemperatureSensorReading] {
                [
                    RawTemperatureSensorReading(name: "PMU tdev1", tempC: 70.2),
                    RawTemperatureSensorReading(name: "PMU tdie8", tempC: 89.6),
                    RawTemperatureSensorReading(name: "NAND CH0 temp", tempC: 61.4)
                ]
            }
        }
        let sampler = SystemSensorSampler(
            runShell: { _, _ in nil },
            rawTemperatureSensorSource: RawSourceStub()
        )

        let output = sampler.nextSample(at: Date())

        XCTAssertNil(output.sample.cpuPcoreTempC)
        XCTAssertNil(output.sample.gpuTempC)
        XCTAssertNil(output.sample.socTempC)
        XCTAssertFalse(output.availability[SensorReadingSources.cpu]?.available ?? true)
        XCTAssertFalse(output.availability[SensorReadingSources.gpu]?.available ?? true)
        XCTAssertFalse(output.availability[SensorReadingSources.soc]?.available ?? true)
        XCTAssertEqual(output.availability[SensorReadingSources.cpu]?.reason, "cpu-temp-unavailable")
        XCTAssertEqual(output.availability[SensorReadingSources.gpu]?.reason, "gpu-temp-unavailable")
        XCTAssertEqual(output.availability[SensorReadingSources.soc]?.reason, "soc-temp-unavailable")
        XCTAssertEqual(output.sample.hottestTemperatureReading(availability: output.availability)?.id, "raw:PMU tdie8")

        let readings = output.sample.temperatureReadings(availability: output.availability)
        XCTAssertTrue(readings.contains { $0.id == "raw:PMU tdie8" && $0.available })
    }

    func testRawSensorLabelsAreFriendly() {
        let sample = SensorSample(
            timestamp: Date(),
            rawTemperatureSensors: [
                RawTemperatureSensorReading(name: "PMU tdie1", tempC: 78.4),
                RawTemperatureSensorReading(name: "PMU2 tdev3", tempC: 65.2),
                RawTemperatureSensorReading(name: "NAND CH0 temp", tempC: 42.9)
            ]
        )
        let readings = sample.temperatureReadings(availability: [
            SensorReadingSources.cpu: .init(available: false, confidence: 0),
            SensorReadingSources.gpu: .init(available: false, confidence: 0),
            SensorReadingSources.soc: .init(available: false, confidence: 0)
        ])

        let rawReadings = readings.filter { $0.id.hasPrefix("raw:") }
        XCTAssertEqual(rawReadings.count, 3)
        XCTAssertTrue(rawReadings.contains { $0.label == "PMU DIE 1" })
        XCTAssertTrue(rawReadings.contains { $0.label == "PMU2 Device 3" })
        XCTAssertTrue(rawReadings.contains { $0.label == "NAND CH0" })
    }

    func testControlStateMachineSafetyPriority() {
        var machine = ControlStateMachine()
        let unknown = HardwareProfile(
            chip: "Apple M1",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "FAN0", controllable: true)]
        )

        _ = machine.apply(event: .discovered, hardwareProfile: unknown)
        XCTAssertEqual(machine.state, .smartControl)

        _ = machine.apply(event: .sensorFault)
        XCTAssertEqual(machine.state, .safetyFallback)
        XCTAssertEqual(machine.source, .safetyMode)

        _ = machine.apply(event: .manualDefault)
        XCTAssertEqual(machine.state, .manualDefault)
        XCTAssertEqual(machine.source, .userManual)
    }

    func testUserModeChangeBringsManualDefaultBackToDiscovering() {
        var machine = ControlStateMachine()
        let unknown = HardwareProfile(
            chip: "Apple M1",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "FAN0", controllable: true)]
        )

        _ = machine.apply(event: .discovered, hardwareProfile: unknown)
        XCTAssertEqual(machine.state, .smartControl)

        _ = machine.apply(event: .manualDefault)
        XCTAssertEqual(machine.state, .manualDefault)

        _ = machine.apply(event: .userModeChange)
        XCTAssertEqual(machine.state, .discovering)
        XCTAssertEqual(machine.source, .appAuto)
    }

    func testThermalPolicyDefaultsAreDeterministic() {
        let policy = ThermalPolicy.defaults(for: .balanced)
        XCTAssertEqual(policy.mode, .balanced)
        XCTAssertFalse(policy.customCurve.isEmpty)
        XCTAssertGreaterThan(policy.targetMinRPM, 0)
        XCTAssertGreaterThan(policy.targetMaxRPM, policy.targetMinRPM)
    }

    func testEngineRampsWithin300RPMPerCycle() {
        let engine = ThermalEngine()
        let score = ThermalScore(value: 95)
        let cmd = engine.buildPolicy(
            from: ThermalPolicy.Mode.performance,
            score: score,
            appBoostActive: false,
            currentRPM: 1200,
            constraints: (min: 1200, max: 6200, rampStep: 300)
        )

        XCTAssertEqual(cmd.rampStep, 300)
        XCTAssertLessThanOrEqual(abs(cmd.targetRPM - 1200), 300)
    }

    func testExternalDisplayBiasIncreasesRPMTarget() {
        let engine = ThermalEngine()
        let score = ThermalScore(value: 98)
        let baseline = engine.buildPolicy(
            from: ThermalPolicy.Mode.balanced,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300)
        )
        let boosted = engine.buildPolicy(
            from: ThermalPolicy.Mode.balanced,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300),
            externalDisplay: true
        )

        XCTAssertGreaterThan(boosted.targetRPM, baseline.targetRPM)
    }

    func testBatteryModeReducesRPMTarget() {
        let engine = ThermalEngine()
        let score = ThermalScore(value: 98)
        let baseline = engine.buildPolicy(
            from: ThermalPolicy.Mode.balanced,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300)
        )
        let batteryAware = engine.buildPolicy(
            from: ThermalPolicy.Mode.balanced,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300),
            onBattery: true
        )

        XCTAssertLessThan(batteryAware.targetRPM, baseline.targetRPM)
    }

    func testCustomProfileCurveCanDrivePolicy() {
        let engine = ThermalEngine()
        let score = ThermalScore(value: 95)
        let baseline = engine.buildPolicy(
            from: .customCurve,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300)
        )
        let tuned = engine.buildPolicy(
            from: .customCurve,
            score: score,
            appBoostActive: false,
            currentRPM: 4880,
            constraints: (min: 1200, max: 6200, rampStep: 300),
            customCurve: [
                .init(score: 0, rpm: 3000),
                .init(score: 95, rpm: 6200),
                .init(score: 100, rpm: 6200)
            ]
        )

        XCTAssertEqual(tuned.action, .setProfile)
        XCTAssertGreaterThan(tuned.targetRPM, baseline.targetRPM)
    }

    func testConservativeModeReducesPolicyRPM() {
        let engine = ThermalEngine()
        let score = ThermalScore(value: 96)
        let baseline = engine.buildPolicy(
            from: .performance,
            score: score,
            appBoostActive: false,
            currentRPM: 5600,
            constraints: (min: 1200, max: 6200, rampStep: 300)
        )
        let conservative = engine.buildPolicy(
            from: .performance,
            score: score,
            appBoostActive: false,
            currentRPM: 5600,
            constraints: (min: 1200, max: 6200, rampStep: 300),
            upgradeConservativeMode: true
        )

        XCTAssertLessThanOrEqual(conservative.targetRPM, baseline.targetRPM)
    }

    func testCustomCurveRequiresValidPoints() {
        let badConfig = ThermalControlConfig(
            customCurve: [
                .init(score: 50, rpm: 2000),
                .init(score: 50, rpm: 2600)
            ]
        )
        let service = FanControlRuntimeService(configuration: badConfig)
        let importResult = service.importConfig(badConfig)
        XCTAssertFalse(importResult.success)
        XCTAssertTrue(importResult.reason.hasPrefix("invalid-config"))
    }

    func testDefaultWhitelistContainsAppTriggerCandidates() {
        let config = ThermalControlConfig()
        let whitelist = Set(config.whiteList.map { $0.lowercased() })

        XCTAssertTrue(whitelist.contains("xcode"))
        XCTAssertTrue(whitelist.contains("android studio"))
        XCTAssertTrue(whitelist.contains("jetbrains idea"))
        XCTAssertTrue(whitelist.contains("final cut pro"))
        XCTAssertTrue(whitelist.contains("davinci resolve"))
        XCTAssertTrue(whitelist.contains("ollama"))
        XCTAssertTrue(whitelist.contains("lm studio"))
        XCTAssertTrue(whitelist.contains("docker"))
        XCTAssertTrue(whitelist.contains("blender"))
    }

    func testWhitelistNormalizationDeduplicatesAndStripsNoise() {
        let config = ThermalControlConfig(whiteList: [
            "  Xcode",
            "xcode ",
            "XCode.app",
            "  JetBrains IDEA  ",
            "Docker.app",
            "",
            "  "
        ])
        let normalized = config.normalized()

        XCTAssertEqual(normalized.whiteList, ["xcode", "jetbrains idea", "docker"])
    }

    func testConfigSnakeCasePayloadCanBeDecodedAndEncoded() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

        let payload = #"""
        {
            "schema_version": 1,
            "profile": "balanced",
            "weights": {
                "cpu": 0.3,
                "gpu": 0.2,
                "soc": 0.2,
                "ssd": 0.1,
                "power": 0.2
            },
            "history_retention": {
                "raw_minutes": 720,
                "aggregate_hours": 360
            },
            "whiteList": ["Xcode"],
            "safety_thresholds": {
                "thermal_safety_score": 82,
                "sustained_seconds": 12,
                "sample_interval_sec": 2,
                "safety_reason_debounce_minutes": 15
            }
        }
        """#.data(using: .utf8)!

        let decoded = try decoder.decode(ThermalControlConfig.self, from: payload)
        XCTAssertTrue(decoded.isValid())
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.profile, "balanced")

        let encoded = try encoder.encode(decoded)
        let output = try JSONSerialization.jsonObject(with: encoded, options: []) as? [String: Any]
        XCTAssertNotNil(output)
        XCTAssertNotNil((output?["schema_version"]))
        XCTAssertNotNil(output?["safety_thresholds"])
    }

    func testConfigSnakeCasePayloadSupportsLegacyAggHoursKey() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        let legacyPayload = #"""
        {
            "schema_version": 1,
            "profile": "balanced",
            "weights": {
                "cpu": 0.3,
                "gpu": 0.2,
                "soc": 0.2,
                "ssd": 0.1,
                "power": 0.2
            },
            "history_retention": {
                "raw_minutes": 720,
                "agg_hours": 360
            },
            "whiteList": ["Xcode"],
            "safety_thresholds": {
                "thermal_safety_score": 82,
                "sustained_seconds": 12,
                "sample_interval_sec": 2,
                "safety_reason_debounce_minutes": 15
            }
        }
        """#.data(using: .utf8)!

        let decoded = try decoder.decode(ThermalControlConfig.self, from: legacyPayload)
        XCTAssertEqual(decoded.historyRetention.aggregateHours, 360)
    }

    func testRuntimeServiceRejectsUncontrollableHardware() {
        let profile = HardwareProfile(
            chip: "MacBookAir",
            deviceModel: "MacBook Air",
            isAppleSilicon: true,
            hasFans: false,
            fans: []
        )
        let service = FanControlRuntimeService(configuration: ThermalControlConfig(), hardwareProfile: profile)
        let command = ControlCommand(
            action: .setProfile,
            targetRPM: 3000,
            minRPM: 1200,
            maxRPM: 6200,
            rampStep: 300,
            reason: "unit"
        )

        let result = service.apply(command)
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.state, .idle)
        XCTAssertEqual(result.failure, .notAvailable)
        XCTAssertEqual(service.currentState().state, .idle)
    }

    func testConfigValidationAndImport() {
        let badConfig = ThermalControlConfig(schemaVersion: 0, profile: "", weights: ThermalWeights(), historyRetention: HistoryRetention(), whiteList: [], safetyThresholds: SafetyThresholds())
        let service = FanControlRuntimeService()
        let bad = service.importConfig(badConfig)
        XCTAssertFalse(bad.success)
        XCTAssertTrue(bad.reason.contains("unsupported-schema-version"))

        let good = ThermalControlConfig()
        let ok = service.importConfig(good)
        XCTAssertTrue(ok.success)
    }

    func testImportConfigPersistsConservativeModeFlag() {
        let service = FanControlRuntimeService(telemetryStore: InMemoryTelemetryStore())
        let config = ThermalControlConfig(profile: "balanced", upgradeConservativeMode: true)

        let result = service.importConfig(config)

        XCTAssertTrue(result.success)
        XCTAssertTrue(service.exportConfig().upgradeConservativeMode)
        XCTAssertTrue(service.currentState().source == .appleDefault || service.currentState().source == .appAuto)
    }

    func testImportConfigReturnsMigrationSuggestion() {
        let service = FanControlRuntimeService()
        let legacy = ThermalControlConfig(schemaVersion: 0, profile: ThermalPolicy.Mode.balanced.rawValue)
        let result = service.importConfig(legacy)
        XCTAssertFalse(result.success)
        XCTAssertTrue(result.reason.lowercased().contains("upgrade"))
        XCTAssertTrue(result.reason.lowercased().contains("schema_version"))
    }

    func testImportConfigUpdatesTelemetryRetentionSettings() {
        let telemetry = RetentionRecordingTelemetryStore()
        let service = FanControlRuntimeService(telemetryStore: telemetry)
        let updated = ThermalControlConfig(
            historyRetention: .init(rawMinutes: 90, aggregateHours: 24),
            safetyThresholds: .init(safetyReasonDebounceMinutes: 12)
        )

        let result = service.importConfig(updated)
        XCTAssertTrue(result.success)
        XCTAssertEqual(telemetry.lastConfiguredHistory.rawMinutes, 90)
        XCTAssertEqual(telemetry.lastConfiguredHistory.aggregateHours, 24)
        XCTAssertEqual(telemetry.lastConfiguredDebounce, 12)
    }

    func testSetModePersistsProfileInConfig() {
        let suiteName = "com.fancontrol.tests.setModePersistence"
        let suite = UserDefaults(suiteName: suiteName)
        suite?.removePersistentDomain(forName: suiteName)
        let store = ConfigStore(suiteName: suiteName)

        let service = FanControlRuntimeService(
            hardwareProfile: HardwareDiscovery.detect(),
            telemetryStore: InMemoryTelemetryStore(),
            configStore: store
        )
        let result = service.setMode(.performance)
        XCTAssertTrue(result.success)
        XCTAssertEqual(service.exportConfig().profile, "performance")
        XCTAssertEqual(service.currentState().activeProfile, "performance")

        let replay = FanControlRuntimeService(
            telemetryStore: InMemoryTelemetryStore(),
            configStore: store
        )
        XCTAssertEqual(replay.exportConfig().profile, "performance")
        suite?.removePersistentDomain(forName: suiteName)
    }

    func testImportedConfigPersistsAcrossServiceRestarts() {
        let suiteName = "com.fancontrol.tests.configstore"
        let suite = UserDefaults(suiteName: suiteName)
        suite?.removePersistentDomain(forName: suiteName)

        let store = ConfigStore(suiteName: suiteName)
        let expectedConfig = ThermalControlConfig(profile: "performance")

        do {
            let firstService = FanControlRuntimeService(
                sensorSampler: DeterministicSensorSampler(),
                telemetryStore: InMemoryTelemetryStore(),
                configStore: store
            )
            let imported = firstService.importConfig(expectedConfig)
            XCTAssertTrue(imported.success)
            XCTAssertEqual(firstService.exportConfig().profile, "performance")
        }

        let secondService = FanControlRuntimeService(
            configuration: ThermalControlConfig(profile: "quiet"),
            hardwareProfile: HardwareDiscovery.detect(),
            sensorSampler: DeterministicSensorSampler(),
            telemetryStore: InMemoryTelemetryStore(),
            configStore: store
        )
        XCTAssertEqual(secondService.exportConfig().profile, "performance")

        let cleared = secondService.resetForUninstall()
        XCTAssertTrue(cleared.success)

        let thirdService = FanControlRuntimeService(
            hardwareProfile: HardwareDiscovery.detect(),
            sensorSampler: DeterministicSensorSampler(),
            telemetryStore: InMemoryTelemetryStore(),
            configStore: store
        )
        XCTAssertEqual(thirdService.exportConfig().profile, ThermalControlConfig().profile)

        suite?.removePersistentDomain(forName: suiteName)
    }

    func testPersistentTelemetryStoreProvidesHourlyAggregates() throws {
        let tempRoot = FileManager.default.temporaryDirectory
        let dbURL = tempRoot.appendingPathComponent("mfancontrol-aggregate-telemetry-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: dbURL)
        }

        let store = PersistentTelemetryStore(
            sampleCapacity: 120,
            eventCapacity: 20,
            snapshotURL: dbURL,
            sampleRetentionMinutes: 1440,
            aggregateRetentionHours: 720,
            eventRetentionHours: 720,
            eventDebounceMinutes: 15
        )

        let now = Date()
        let base = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 3600) * 3600)
        let sameHour = base
        let nearNext = base.addingTimeInterval(1200)
        let nextHour = base.addingTimeInterval(3700)

        store.append(
            TelemetrySampleRecord(
                thermalScore: 40,
                source: "unit",
                reason: "sample-1",
                timestamp: sameHour
            )
        )
        store.append(
            TelemetrySampleRecord(
                thermalScore: 60,
                source: "unit",
                reason: "sample-2",
                timestamp: nearNext
            )
        )
        store.append(
            TelemetrySampleRecord(
                thermalScore: 90,
                source: "unit",
                reason: "sample-3",
                timestamp: nextHour
            )
        )

        let aggregates = store.fetchRecentAggregates(limit: 10)
        XCTAssertEqual(aggregates.count, 2)
        XCTAssertEqual(aggregates[0].sampleCount, 2)
        XCTAssertEqual(aggregates[1].sampleCount, 1)
        XCTAssertEqual(aggregates[0].average, 50, accuracy: 0.01)
        XCTAssertEqual(aggregates[1].average, 90, accuracy: 0.01)
    }

    func testUninstallResetRestoresDefaultsAndClearsTelemetry() {
        let suiteName = "com.fancontrol.tests.uninstall"
        let suite = UserDefaults(suiteName: suiteName)
        suite?.removePersistentDomain(forName: suiteName)
        let store = ConfigStore(suiteName: suiteName)
        let telemetry = InMemoryTelemetryStore()

        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FanControlRuntimeService(
            configuration: ThermalControlConfig(profile: "performance"),
            hardwareProfile: profile,
            sensorSampler: DeterministicSensorSampler(),
            telemetryStore: telemetry,
            configStore: store
        )
        _ = service.importConfig(ThermalControlConfig(profile: "performance"))
        _ = service.apply(
            ControlCommand(
                action: .setProfile,
                targetRPM: 2400,
                minRPM: 1200,
                maxRPM: 6200,
                rampStep: 300,
                reason: "test"
            )
        )
        XCTAssertFalse(service.recentEvents(limit: 10).isEmpty)

        let reset = service.resetForUninstall()
        XCTAssertTrue(reset.success)
        XCTAssertEqual(reset.state, .manualDefault)
        XCTAssertEqual(reset.reason, "uninstall-sequence-complete")
        XCTAssertTrue(service.recentEvents(limit: 10).isEmpty)

        let recreated = FanControlRuntimeService(
            configuration: ThermalControlConfig(profile: "balanced"),
            hardwareProfile: profile,
            telemetryStore: telemetry,
            configStore: store
        )
        XCTAssertEqual(recreated.exportConfig().profile, ThermalControlConfig().profile)

        suite?.removePersistentDomain(forName: suiteName)
    }

    func testUninstallSequenceInvokesCleanupHook() {
        let suiteName = "com.fancontrol.tests.uninstallCleanup"
        let suite = UserDefaults(suiteName: suiteName)
        suite?.removePersistentDomain(forName: suiteName)
        let store = ConfigStore(suiteName: suiteName)
        var cleanupInvoked = false
        let cleanup = {
            cleanupInvoked = true
            return true
        }

        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FanControlRuntimeService(
            configuration: ThermalControlConfig(profile: "performance"),
            hardwareProfile: profile,
            telemetryStore: InMemoryTelemetryStore(),
            configStore: store,
            uninstallCleanup: cleanup
        )
        let result = service.resetForUninstall()

        XCTAssertTrue(cleanupInvoked)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.reason, "uninstall-sequence-complete")
        suite?.removePersistentDomain(forName: suiteName)
    }

    func testServiceEntersSafetyWhenSensorUnavailable() {
        struct EmptySampler: SensorSampler {
            func nextSample(at timestamp: Date) -> SensorSampleOutput {
                SensorSampleOutput(
                    sample: SensorSample(timestamp: timestamp),
                    availability: [
                        SensorReadingSources.cpu: .init(available: false, confidence: 0, reason: "missing"),
                        SensorReadingSources.gpu: .init(available: false, confidence: 0, reason: "missing"),
                        SensorReadingSources.soc: .init(available: false, confidence: 0, reason: "missing")
                    ],
                    throttleState: .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "missing"),
                    powerSource: "unknown"
                )
            }
        }

        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FanControlRuntimeService(
            hardwareProfile: profile,
            sensorSampler: EmptySampler(),
            telemetryStore: InMemoryTelemetryStore(capacity: 30)
        )
        _ = service.readSensorSample()
        let command = ControlCommand(action: .setProfile, targetRPM: 1800)
        let result = service.apply(command)
        let state = service.currentState()

        XCTAssertFalse(result.success)
        XCTAssertEqual(state.state, .safetyFallback)
    }

    func testRuntimeServiceRecoversToSmartControlAfterSystemWakeWithGoodSensorSample() {
        final class WakeSampler: SensorSampler {
            private var reads = 0

            func nextSample(at timestamp: Date) -> SensorSampleOutput {
                reads += 1
                if reads == 1 {
                    return SensorSampleOutput(
                        sample: SensorSample(timestamp: timestamp),
                        availability: [
                            SensorReadingSources.cpu: .init(available: false, confidence: 0, reason: "transient-miss"),
                            SensorReadingSources.gpu: .init(available: false, confidence: 0, reason: "transient-miss"),
                            SensorReadingSources.soc: .init(available: false, confidence: 0, reason: "transient-miss")
                        ],
                        throttleState: .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "transient-miss"),
                        powerSource: "unknown"
                    )
                }

                return SensorSampleOutput(
                    sample: SensorSample(
                        timestamp: timestamp,
                        cpuPcoreTempC: 66,
                        cpuEcoreTempC: 62,
                        gpuTempC: 64,
                        socTempC: 63,
                        ssdTempC: 40,
                        batteryTempC: 35,
                        memoryTempC: 44,
                        powerWatts: 28,
                        sustainedLoadSec: 14
                    ),
                    availability: [
                        SensorReadingSources.cpu: .init(available: true, confidence: 1, reason: "recovered"),
                        SensorReadingSources.gpu: .init(available: true, confidence: 1, reason: "recovered"),
                        SensorReadingSources.soc: .init(available: true, confidence: 1, reason: "recovered")
                    ],
                    throttleState: .init(cpuThermalThrottled: false, gpuThermalThrottled: false, reason: "ok"),
                    powerSource: "AC"
                )
            }
        }

        let profile = HardwareProfile(
            chip: "Apple M2",
            deviceModel: "MacBookPro",
            isAppleSilicon: true,
            hasFans: true,
            fans: [FanCapability(fanCount: 1, minRPM: 1200, maxRPM: 6200, modelIdentifier: "F0", controllable: true)]
        )
        let service = FanControlRuntimeService(
            hardwareProfile: profile,
            sensorSampler: WakeSampler(),
            telemetryStore: InMemoryTelemetryStore(capacity: 30)
        )

        _ = service.restoreToAppleDefault(reason: "manual-default")
        _ = service.readSensorSample()
        XCTAssertEqual(service.currentState().state, .safetyFallback)

        let wakeResult = service.handleSystemWake()
        let postWake = service.currentState()

        XCTAssertTrue(wakeResult.success)
        XCTAssertEqual(postWake.state, .smartControl)
        XCTAssertEqual(postWake.source, .appAuto)
    }
}
