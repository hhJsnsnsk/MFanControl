import Foundation
import MFanControlShared

let args = CommandLine.arguments
let xpc = XPCClient()

if args.count < 2 {
    print(CLIUsage.text)
    exit(0)
}

let commandRaw = args[1]
guard let command = CLICommand(rawValue: commandRaw) else {
    print("unknown command: \(commandRaw)")
    print(CLIUsage.text)
    exit(0)
}

switch command {
case .status:
    let sample = xpc.readSensorSample()
    let state = xpc.currentState()
    print("state=\(state.state.rawValue)")
    print("source=\(state.source.rawValue)")
    print("mode=\(state.activeProfile)")
    print("rpm=current:\(state.currentRPM) target:\(state.targetRPM)")
    if let score = state.thermalScore {
        print("thermalScore=\(Int(score))")
    }
    if let hottest = sample.hottestTemperatureReading(availability: state.sensorAvailability),
       let temp = hottest.valueC {
        print("maxTemperature=\(hottest.label) \(Int(temp))C")
    } else {
        print("maxTemperature=unavailable")
    }
    print("sensors:")
    for reading in sample.temperatureReadings(availability: state.sensorAvailability) {
        if reading.available, let value = reading.valueC {
            print(" - \(reading.label)=\(Int(value))C confidence=\(String(format: "%.2f", reading.confidence))")
        } else {
            print(" - \(reading.label)=unavailable reason=\(reading.reason)")
        }
    }
    if let watts = sample.powerWatts {
        print("powerWatts=\(String(format: "%.2f", watts))")
    } else {
        print("powerWatts=unavailable")
    }
case .history:
    let n = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let records = xpc.recentSamples(limit: n)
    if records.isEmpty {
        print("history: empty")
    } else {
        for item in records {
            print("\(item.timestamp): score=\(item.thermalScore) source=\(item.source) reason=\(item.reason)")
        }
    }
case .events:
    let n = args.count > 2 ? Int(args[2]) ?? 10 : 10
    let records = xpc.recentEvents(limit: n)
    if records.isEmpty {
        print("events: empty")
    } else {
        for item in records {
            let payload = item.payload
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: ", ")
            if payload.isEmpty {
                print("\(item.timestamp): [\(item.level)] \(item.state) \(item.reason)")
            } else {
                print("\(item.timestamp): [\(item.level)] \(item.state) \(item.reason) \(payload)")
            }
        }
    }
case .setMode:
    if args.count < 3 {
        print("set-mode requires quiet|balanced|performance|customCurve")
        exit(0)
    }
    let mode = args[2]
    guard let parsed = ThermalPolicy.Mode(rawValue: mode) else {
        print("unsupported mode: \(mode)")
        exit(0)
    }
    _ = xpc.setMode(parsed)
    print("mode set: \(parsed.rawValue)")
case .whitelist:
    guard args.count >= 3 else {
        print("whitelist requires: list | add <name...> | remove <name...>")
        exit(0)
    }
    let action = args[2].lowercased()
    switch action {
    case "list":
        let names = xpc.exportConfig().whiteList.sorted()
        if names.isEmpty {
            print("whitelist: empty")
        } else {
            print("whitelist:")
            names.forEach { print(" - \($0)") }
        }
    case "add":
        let names = Array(args.dropFirst(3))
        guard !names.isEmpty else {
            print("whitelist add requires at least one process name")
            exit(0)
        }
        var config = xpc.exportConfig()
        config.whiteList.append(contentsOf: names)
        let result = xpc.importConfig(config)
        print(result.success ? "whitelist updated" : "whitelist add failed: \(result.reason)")
    case "remove":
        let names = Array(args.dropFirst(3))
        guard !names.isEmpty else {
            print("whitelist remove requires at least one process name")
            exit(0)
        }
        var config = xpc.exportConfig()
        let removed = Set(names.map { ProcessIdentityMatcher.normalizedName($0) })
        let previousCount = config.whiteList.count
        config.whiteList = config.whiteList.filter {
            !removed.contains(ProcessIdentityMatcher.normalizedName($0))
        }
        let result = xpc.importConfig(config)
        if result.success {
            let removedCount = previousCount - config.whiteList.count
            print("whitelist updated: removed \(removedCount)")
        } else {
            print("whitelist remove failed: \(result.reason)")
        }
    default:
        print("whitelist action must be list/add/remove")
    }
case .setCustomCurve:
    if args.count < 4 {
        print("set-custom-curve requires at least two points like: 50:1200 80:2400")
        exit(0)
    }
    var curve: [ThermalPolicy.CurvePoint] = []
    for token in args.dropFirst(2) {
        let segments = token.split(separator: ":")
        if segments.count != 2 {
            print("invalid curve token: \(token)")
            exit(0)
        }
        guard
            let score = Int(segments[0]),
            let rpm = Int(segments[1])
        else {
            print("invalid curve token: \(token)")
            exit(0)
        }
        curve.append(.init(score: score, rpm: rpm))
    }
    var config = xpc.exportConfig()
    config.customCurve = curve
    let result = xpc.importConfig(config)
    if result.success {
        print("custom curve updated: \(curve.count) points")
    } else {
        print("custom-curve failed: \(result.reason)")
    }
case .setRPM:
    guard args.count >= 3, let rpm = Int(args[2]), rpm > 0 else {
        print("set-rpm requires a positive integer")
        exit(0)
    }
    let profile = xpc.discoverHardwareProfile()
    guard let fan = profile.fans.first else {
        print("set-rpm failed: no fan detected")
        exit(0)
    }
    let command = ControlCommand(
        action: .setProfile,
        targetRPM: rpm,
        minRPM: fan.minRPM,
        maxRPM: fan.maxRPM,
        rampStep: max(1, fan.maxRPM - fan.minRPM),
        reason: "cli-set-rpm"
    )
    let result = xpc.apply(command)
    if result.success {
        print("set-rpm success: \(rpm) (state=\(result.state.rawValue) source=\(result.source.rawValue))")
    } else {
        print("set-rpm failed: \(result.reason) (state=\(result.state.rawValue) source=\(result.source.rawValue) failure=\(result.failure.rawValue))")
    }
case .forceDefault:
    _ = xpc.restoreToAppleDefault(reason: "cli-force-default")
    print("restore default issued")
case .exportConfig:
    if args.count < 3 {
        print("export-config requires file path")
        exit(0)
    }
    let path = args[2]
    let config = xpc.exportConfig()
    do {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: URL(fileURLWithPath: path))
        print("exported to \(path)")
    } catch {
        print("export failed: \(error)")
        exit(1)
    }
case .importConfig:
    if args.count < 3 {
        print("import-config requires file path")
        exit(0)
    }
    let path = args[2]
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let config = try decoder.decode(ThermalControlConfig.self, from: data)
        let result = xpc.importConfig(config)
        print(result.success ? "import success" : "import failed: \(result.reason)")
    } catch {
        print("import failed: \(error)")
        exit(1)
    }
case .uninstall:
    let result = xpc.resetForUninstall()
    print(result.success ? "uninstall-cleanup-complete" : "uninstall-failed: \(result.reason)")
}
