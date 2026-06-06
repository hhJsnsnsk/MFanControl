import Foundation

public struct ConfigStoreKeys {
    public static let profile = "mfancontrol.profile"
    public static let weights = "mfancontrol.weights"
    public static let safetyThresholds = "mfancontrol.safety.thresholds"
    public static let whitelist = "mfancontrol.app.whitelist"
}

public final class ConfigStore {
    private let defaults = UserDefaults.standard

    public init() {}

    public func set<T: Codable>(_ value: T, forKey key: String) {
        do {
            let data = try JSONEncoder().encode(value)
            defaults.set(data, forKey: key)
        } catch {
            print("ConfigStore encode failed: \(error)")
        }
    }

    public func get<T: Codable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func remove(_ key: String) {
        defaults.removeObject(forKey: key)
    }
}
