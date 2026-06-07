import Foundation
import MFanControlShared

public final class FanControlXPCExportedObject: NSObject, FanControlXPCServiceProtocol {
    private let daemon = FanControlDaemon.shared

    public func currentState(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.serviceSnapshot(), reply)
    }

    public func apply(_ commandData: Data, _ reply: @escaping (Data?, String?) -> Void) {
        decodeAndExecute(model: ControlCommand.self, from: commandData) { value in
            replyEncoded(self.daemon.applyCommand(value), reply)
        } onError: { error in
            reply(nil, error.localizedDescription)
        }
    }

    public func restoreToAppleDefault(_ reason: String, _ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.restoreDefault(reason: reason), reply)
    }

    public func setMode(_ mode: String, _ reply: @escaping (Data?, String?) -> Void) {
        guard let parsedMode = ThermalPolicy.Mode(rawValue: mode) else {
            reply(nil, "unsupported-mode")
            return
        }
        replyEncoded(daemon.setMode(parsedMode), reply)
    }

    public func discoverHardwareProfile(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.discoverHardware(), reply)
    }

    public func readSensorSample(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.readSensorSample(), reply)
    }

    public func exportConfig(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.exportConfig(), reply)
    }

    public func importConfig(_ configData: Data, _ reply: @escaping (Data?, String?) -> Void) {
        decodeAndExecute(model: ThermalControlConfig.self, from: configData) { value in
            replyEncoded(self.daemon.importConfig(value), reply)
        } onError: { error in
            reply(nil, error.localizedDescription)
        }
    }

    public func recentSamples(limit: Int, _ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.recentSamples(limit: limit), reply)
    }

    public func recentEvents(limit: Int, _ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.recentEvents(limit: limit), reply)
    }

    public func resetForUninstall(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.resetForUninstall(), reply)
    }

    public func systemWake(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.handleSystemWake(), reply)
    }

    public func systemSleep(_ reply: @escaping (Data?, String?) -> Void) {
        replyEncoded(daemon.handleSystemSleep(), reply)
    }

    private func replyEncoded<T: Encodable>(_ value: T, _ reply: @escaping (Data?, String?) -> Void) {
        do {
            let payload = try FanControlXPCSerialization.encode(value)
            reply(payload, nil)
        } catch {
            reply(nil, error.localizedDescription)
        }
    }

    private func decodeAndExecute<T: Decodable>(model: T.Type, from data: Data, execute: (T) -> Void, onError: (Error) -> Void) {
        do {
            let decoded = try FanControlXPCSerialization.decode(T.self, from: data)
            execute(decoded)
        } catch {
            onError(error)
        }
    }
}

public final class FanControlXPCListener: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let service: FanControlXPCExportedObject

    public init(serviceName: String) {
        self.listener = NSXPCListener(machServiceName: serviceName)
        self.service = FanControlXPCExportedObject()
        super.init()
        self.listener.delegate = self
    }

    public func start() {
        listener.resume()
    }

    public func stop() {
        listener.invalidate()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let exportedInterface = NSXPCInterface(with: FanControlXPCServiceProtocol.self)
        connection.exportedInterface = exportedInterface
        connection.exportedObject = service
        connection.resume()
        return true
    }
}
