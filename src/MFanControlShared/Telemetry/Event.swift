import Foundation

public enum EventLevel: String, Codable, Sendable {
    case info
    case warn
    case error
}

public struct EventRecord: Codable, Sendable {
    public var timestamp: Date
    public var level: EventLevel
    public var state: String
    public var reason: String
    public var payload: [String: String]

    public init(
        level: EventLevel,
        state: String,
        reason: String,
        payload: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.timestamp = timestamp
        self.level = level
        self.state = state
        self.reason = reason
        self.payload = payload
    }
}
