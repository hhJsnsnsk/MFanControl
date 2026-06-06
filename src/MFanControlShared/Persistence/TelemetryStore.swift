import Foundation

public struct TelemetrySampleRecord: Codable, Sendable {
    public let timestamp: Date
    public let thermalScore: Double
    public let source: String
    public let reason: String

    public init(thermalScore: Double, source: String, reason: String, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.thermalScore = thermalScore
        self.source = source
        self.reason = reason
    }
}

public protocol TelemetryStoreProtocol {
    func append(_ record: TelemetrySampleRecord)
    func fetchRecent(limit: Int) -> [TelemetrySampleRecord]
}

public final class InMemoryTelemetryStore: TelemetryStoreProtocol {
    private var items: [TelemetrySampleRecord] = []
    private let capacity: Int

    public init(capacity: Int = 120) {
        self.capacity = capacity
    }

    public func append(_ record: TelemetrySampleRecord) {
        items.append(record)
        if items.count > capacity {
            items.removeFirst(items.count - capacity)
        }
    }

    public func fetchRecent(limit: Int) -> [TelemetrySampleRecord] {
        let upper = max(0, min(limit, items.count))
        return Array(items.suffix(upper))
    }
}
