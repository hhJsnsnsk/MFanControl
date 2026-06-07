import Foundation

public struct ConfigStoreKeys {
    public static let hardwareProfile = "mfancontrol.hardware.profile"
    public static let profile = "mfancontrol.profile"
    public static let weights = "mfancontrol.weights"
    public static let thermalConfig = "mfancontrol.thermal.config"
    public static let safetyThresholds = "mfancontrol.safety.thresholds"
    public static let whitelist = "mfancontrol.app.whitelist"
    public static let historyRetention = "mfancontrol.history.retention"
}

public final class ConfigStore {
    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let jsonDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    private let defaults: UserDefaults

    public init(suiteName: String? = nil) {
        if let suite = suiteName, let suiteDefaults = UserDefaults(suiteName: suite) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
    }

    public func set<T: Codable>(_ value: T, forKey key: String) {
        do {
            let data = try Self.jsonEncoder.encode(value)
            defaults.set(data, forKey: key)
        } catch {
            print("ConfigStore encode failed: \(error)")
        }
    }

    public func get<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? Self.jsonDecoder.decode(type, from: data)
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }

    public func removeAll() {
        defaults.dictionaryRepresentation().keys.forEach { key in
            guard key.hasPrefix("mfancontrol.") else { return }
            defaults.removeObject(forKey: key)
        }
    }
}
