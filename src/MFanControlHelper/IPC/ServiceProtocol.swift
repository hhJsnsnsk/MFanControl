import Foundation
import MFanControlShared

public enum FanControlXPCConnectionMode: String, Codable, CaseIterable {
    case auto
    case localOnly
    case remoteOnly
}

public enum FanControlXPCDefaults {
    public static let serviceName = "com.starrysky.MFanControlHelper.xpc"
    public static let helperServiceLabel = "com.starrysky.MFanControlHelper"
    public static let useRemoteEnv = "MFANCONTROL_USE_XPC"
    public static let helperLaunchdServiceLabelEnv = "MFANCONTROL_HELPER_SERVICE_NAME"
    public static let helperServiceNameEnv = "MFANCONTROL_HELPER_SERVICE_NAME"
}

@objc public protocol FanControlXPCServiceProtocol: NSObjectProtocol {
    func currentState(_ reply: @escaping (Data?, String?) -> Void)
    func apply(_ commandData: Data, _ reply: @escaping (Data?, String?) -> Void)
    func restoreToAppleDefault(_ reason: String, _ reply: @escaping (Data?, String?) -> Void)
    func setMode(_ mode: String, _ reply: @escaping (Data?, String?) -> Void)
    func discoverHardwareProfile(_ reply: @escaping (Data?, String?) -> Void)
    func readSensorSample(_ reply: @escaping (Data?, String?) -> Void)
    func exportConfig(_ reply: @escaping (Data?, String?) -> Void)
    func importConfig(_ configData: Data, _ reply: @escaping (Data?, String?) -> Void)
    func recentSamples(limit: Int, _ reply: @escaping (Data?, String?) -> Void)
    func recentEvents(limit: Int, _ reply: @escaping (Data?, String?) -> Void)
    func resetForUninstall(_ reply: @escaping (Data?, String?) -> Void)
    func systemWake(_ reply: @escaping (Data?, String?) -> Void)
    func systemSleep(_ reply: @escaping (Data?, String?) -> Void)
    func setLoggingEnabled(_ enabled: Bool, _ reply: @escaping (Data?, String?) -> Void)
}

public enum FanControlXPCError: Error {
    case unavailable(String)
    case invalidPayload
    case timeout
}

public enum FanControlXPCSerialization {
    public static let encoder = JSONEncoder()
    public static let decoder = JSONDecoder()

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(T.self, from: data)
    }

    public static func failureResult(_ reason: String) -> FanControlResult {
        .init(success: false, reason: reason, failure: .hardwareUnreachable, state: .safetyFallback, source: .safetyMode)
    }
}
