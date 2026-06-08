import Foundation
import MFanControlShared

private enum XPCHostTransportMode {
    case local
    case remote(String)
}

public final class XPCHost {
    private let daemon = FanControlDaemon.shared
    private let transport: XPCHostTransportMode
    private let timeout: TimeInterval

    public init(mode: FanControlXPCConnectionMode = .auto, serviceName: String? = nil, timeout: TimeInterval = 0.2) {
        let requestedMode = ProcessInfo.processInfo.environment[FanControlXPCDefaults.useRemoteEnv].flatMap { env -> FanControlXPCConnectionMode? in
            if env == "1" { return .remoteOnly }
            if env == "0" { return .localOnly }
            return nil
        }
        let effectiveMode = requestedMode ?? mode
        let resolvedServiceName = serviceName
            ?? ProcessInfo.processInfo.environment[FanControlXPCDefaults.helperServiceNameEnv]
            ?? FanControlXPCDefaults.serviceName

        switch effectiveMode {
        case .localOnly:
            self.transport = .local
        case .remoteOnly:
            self.transport = .remote(resolvedServiceName)
        case .auto:
            if ProcessInfo.processInfo.environment[FanControlXPCDefaults.useRemoteEnv] == "1"
                || Self.isRemoteServiceRunning(serviceName: resolvedServiceName) {
                self.transport = .remote(resolvedServiceName)
            } else {
                self.transport = .local
            }
        }

        self.timeout = max(0.05, timeout)
    }

    public func start() {
        if case .remote = transport {
            _ = ensureXPCAvailable()
        }
    }

    public func status() -> FanControlSnapshot {
        currentState()
    }

    public func apply(_ command: ControlCommand) -> FanControlResult {
        do {
            let commandData = try FanControlXPCSerialization.encode(command)
            return try call(
                withFallback: { [daemon] in
                    daemon.applyCommand(command)
                },
                invocation: { proxy, reply in
                    proxy.apply(commandData, reply)
                }
            )
        } catch {
            return FanControlXPCSerialization.failureResult("xpc-transport-failed:\(error)")
        }
    }

    public func restoreDefault() -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.restoreDefault(reason: "xpc-restore")
                },
                invocation: { proxy, reply in
                    proxy.restoreToAppleDefault("xpc-restore", reply)
                }
            )
        } catch {
            return daemon.restoreDefault(reason: "xpc-restore")
        }
    }

    public func restoreToAppleDefault(reason: String) -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon, reason] in
                    daemon.restoreDefault(reason: reason)
                },
                invocation: { proxy, reply in
                    proxy.restoreToAppleDefault(reason, reply)
                }
            )
        } catch {
            return daemon.restoreDefault(reason: reason)
        }
    }

    public func setMode(_ mode: ThermalPolicy.Mode) -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon, mode] in
                    daemon.setMode(mode)
                },
                invocation: { proxy, reply in
                    proxy.setMode(mode.rawValue, reply)
                }
            )
        } catch {
            return daemon.setMode(mode)
        }
    }

    public func discoverHardwareProfile() -> HardwareProfile {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.discoverHardware()
                },
                invocation: { proxy, reply in
                    proxy.discoverHardwareProfile(reply)
                }
            )
        } catch {
            return daemon.discoverHardware()
        }
    }

    public func readSensorSample() -> SensorSample {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.readSensorSample()
                },
                invocation: { proxy, reply in
                    proxy.readSensorSample(reply)
                }
            )
        } catch {
            return daemon.readSensorSample()
        }
    }

    public func exportConfig() -> ThermalControlConfig {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.exportConfig()
                },
                invocation: { proxy, reply in
                    proxy.exportConfig(reply)
                }
            )
        } catch {
            return daemon.exportConfig()
        }
    }

    public func importConfig(_ config: ThermalControlConfig) -> FanControlResult {
        do {
            let configData = try FanControlXPCSerialization.encode(config)
            return try call(
                withFallback: { [daemon, config] in
                    daemon.importConfig(config)
                },
                invocation: { proxy, reply in
                    proxy.importConfig(configData, reply)
                }
            )
        } catch {
            return daemon.importConfig(config)
        }
    }

    public func recentSamples(limit: Int) -> [TelemetrySampleRecord] {
        do {
            return try call(
                withFallback: { [daemon, limit] in
                    daemon.recentSamples(limit: limit)
                },
                invocation: { proxy, reply in
                    proxy.recentSamples(limit: limit, reply)
                }
            )
        } catch {
            return daemon.recentSamples(limit: limit)
        }
    }

    public func recentEvents(limit: Int) -> [TelemetryEventRecord] {
        do {
            return try call(
                withFallback: { [daemon, limit] in
                    daemon.recentEvents(limit: limit)
                },
                invocation: { proxy, reply in
                    proxy.recentEvents(limit: limit, reply)
                }
            )
        } catch {
            return daemon.recentEvents(limit: limit)
        }
    }

    public func resetForUninstall() -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.resetForUninstall()
                },
                invocation: { proxy, reply in
                    proxy.resetForUninstall(reply)
                }
            )
        } catch {
            return daemon.resetForUninstall()
        }
    }

    public func systemWake() -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.handleSystemWake()
                },
                invocation: { proxy, reply in
                    proxy.systemWake(reply)
                }
            )
        } catch {
            return daemon.handleSystemWake()
        }
    }

    public func systemSleep() -> FanControlResult {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.handleSystemSleep()
                },
                invocation: { proxy, reply in
                    proxy.systemSleep(reply)
                }
            )
        } catch {
            return daemon.handleSystemSleep()
        }
    }

    public func setLoggingEnabled(_ enabled: Bool) {
        MFanLogger.isEnabled = enabled
        if case .remote = transport {
            _ = try? createRemoteProxy().setLoggingEnabled(enabled) { _, _ in }
        }
    }

    public func currentState() -> FanControlSnapshot {
        do {
            return try call(
                withFallback: { [daemon] in
                    daemon.serviceSnapshot()
                },
                invocation: { proxy, reply in
                    proxy.currentState(reply)
                }
            )
        } catch {
            return daemon.serviceSnapshot()
        }
    }

    private func ensureXPCAvailable() -> Bool {
        guard case .remote = transport else {
            return true
        }

        do {
            _ = try createRemoteProxy()
            return true
        } catch {
            return false
        }
    }

    private static func isRemoteServiceRunning(serviceName: String) -> Bool {
        let label = ProcessInfo.processInfo.environment[FanControlXPCDefaults.helperLaunchdServiceLabelEnv]
            ?? FanControlXPCDefaults.helperServiceLabel
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["launchctl", "print", "system/\(label)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            return false
        }
        return output.contains("state = running") && output.contains(serviceName)
    }

    private func createRemoteProxy() throws -> FanControlXPCServiceProtocol {
        guard case .remote(let serviceName) = transport else {
            throw FanControlXPCError.unavailable("local mode")
        }

        let connection = NSXPCConnection(machServiceName: serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: FanControlXPCServiceProtocol.self)
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak connection] _ in
            connection?.invalidate()
        }) as? FanControlXPCServiceProtocol else {
            connection.invalidate()
            throw FanControlXPCError.unavailable("xpc proxy unavailable")
        }

        return proxy
    }

    private func call<T: Codable>(
        withFallback fallback: () -> T,
        invocation: (_ proxy: FanControlXPCServiceProtocol, _ reply: @escaping (Data?, String?) -> Void) -> Void
    ) throws -> T {
        guard case .remote = transport else {
            return fallback()
        }

        guard let proxy = try? createRemoteProxy() else {
            throw FanControlXPCError.unavailable("xpc proxy unavailable")
        }

        var payload: T?
        var responseError: String?
        let semaphore = DispatchSemaphore(value: 0)

        invocation(proxy) { data, error in
            responseError = error
            if let raw = data {
                payload = try? FanControlXPCSerialization.decode(T.self, from: raw)
            }
            semaphore.signal()
        }

        let waited = semaphore.wait(timeout: .now() + timeout)
        if waited == .timedOut {
            throw FanControlXPCError.timeout
        }
        if responseError != nil {
            throw FanControlXPCError.unavailable("xpc request failed")
        }
        if let payload {
            return payload
        }
        throw FanControlXPCError.invalidPayload
    }
}
