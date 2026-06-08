import Foundation
import SQLite3

public struct TelemetrySampleRecord: Codable, Sendable {
    public let timestamp: Date
    public let thermalScore: Double
    public let source: String
    public let reason: String
    public let targetRPM: Int
    public let currentRPM: Int

    public init(thermalScore: Double, source: String, reason: String, targetRPM: Int = 0, currentRPM: Int = 0, timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.thermalScore = thermalScore
        self.source = source
        self.reason = reason
        self.targetRPM = targetRPM
        self.currentRPM = currentRPM
    }
}

public struct TelemetryEventRecord: Codable, Sendable {
    public let timestamp: Date
    public let state: String
    public let level: String
    public let reason: String
    public let payload: [String: String]

    public init(state: String, level: String, reason: String, payload: [String: String] = [:], timestamp: Date = Date()) {
        self.timestamp = timestamp
        self.state = state
        self.level = level
        self.reason = reason
        self.payload = payload
    }
}

public struct TelemetryAggregateRecord: Codable, Sendable {
    public let hourBucket: Int64
    public let average: Double
    public let sampleCount: Int
    public let lastSeen: Date

    public init(hourBucket: Int64, average: Double, sampleCount: Int, lastSeen: Date) {
        self.hourBucket = hourBucket
        self.average = average
        self.sampleCount = sampleCount
        self.lastSeen = lastSeen
    }
}

public protocol TelemetryStoreProtocol {
    func append(_ record: TelemetrySampleRecord)
    func fetchRecent(limit: Int) -> [TelemetrySampleRecord]
    func appendEvent(_ event: TelemetryEventRecord)
    func fetchRecentEvents(limit: Int) -> [TelemetryEventRecord]
    func clear()
    func reconfigureRetention(historyRetention: HistoryRetention, eventDebounceMinutes: Double)
    func fetchRecentAggregates(limit: Int) -> [TelemetryAggregateRecord]
}

public extension TelemetryStoreProtocol {
    func fetchRecentAggregates(limit: Int) -> [TelemetryAggregateRecord] {
        []
    }
}

public final class InMemoryTelemetryStore: TelemetryStoreProtocol {
    private var items: [TelemetrySampleRecord] = []
    private var events: [TelemetryEventRecord] = []
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

    public func appendEvent(_ event: TelemetryEventRecord) {
        events.append(event)
        if events.count > capacity {
            events.removeFirst(events.count - capacity)
        }
    }

    public func fetchRecentEvents(limit: Int) -> [TelemetryEventRecord] {
        let upper = max(0, min(limit, events.count))
        return Array(events.suffix(upper))
    }

    public func fetchRecentAggregates(limit: Int) -> [TelemetryAggregateRecord] {
        let now = Date().timeIntervalSince1970
        let normalized: [TelemetryAggregateRecord] = items.reduce(into: [Int64: (sum: Double, count: Double, lastSeen: TimeInterval)]()) { result, item in
            let bucket = Int64(floor(item.timestamp.timeIntervalSince1970 / 3600))
            let previous = result[bucket] ?? (sum: 0, count: 0, lastSeen: 0)
            result[bucket] = (
                sum: previous.sum + item.thermalScore,
                count: previous.count + 1,
                lastSeen: max(previous.lastSeen, item.timestamp.timeIntervalSince1970)
            )
        }
        .map { bucket, value in
            TelemetryAggregateRecord(
                hourBucket: bucket,
                average: value.count == 0 ? 0 : value.sum / value.count,
                sampleCount: Int(value.count),
                lastSeen: Date(timeIntervalSince1970: value.lastSeen)
            )
        }
        .sorted { $0.hourBucket < $1.hourBucket }

        let capped = normalized.filter { now - $0.lastSeen.timeIntervalSince1970 <= 60 * 60 * 24 * 30 }
        let upper = max(0, min(limit, capped.count))
        return Array(capped.suffix(upper))
    }

    public func clear() {
        items.removeAll()
        events.removeAll()
    }

    public func reconfigureRetention(historyRetention: HistoryRetention, eventDebounceMinutes: Double) {
        _ = historyRetention
        _ = eventDebounceMinutes
    }
}

private struct TelemetrySnapshot: Codable, Sendable {
    var samples: [TelemetrySampleRecord]
    var events: [TelemetryEventRecord]
}

public final class PersistentTelemetryStore: TelemetryStoreProtocol {
    private let snapshotURL: URL
    private let queue = DispatchQueue(label: "mfancontrol.telemetry.store", qos: .utility)
    private var sampleRetentionSeconds: TimeInterval
    private var aggregateRetentionHours: Int
    private var eventRetentionHours: Int
    private var eventDebounceSeconds: TimeInterval

    private var db: OpaquePointer?

    public init(
        sampleCapacity: Int = 120,
        eventCapacity: Int = 120,
        snapshotURL: URL? = nil,
        sampleRetentionMinutes: Int = 1440,
        aggregateRetentionHours: Int = 720,
        eventRetentionHours: Int = 720,
        eventDebounceMinutes: Double = 15
    ) {
        self.snapshotURL = snapshotURL ?? Self.defaultSnapshotURL
        self.sampleRetentionSeconds = TimeInterval(max(1, sampleRetentionMinutes)) * 60
        self.aggregateRetentionHours = max(1, aggregateRetentionHours)
        self.eventRetentionHours = max(1, eventRetentionHours)
        self.eventDebounceSeconds = max(0, eventDebounceMinutes * 60)
        _ = sampleCapacity
        _ = eventCapacity
        setupDatabase()
    }

    public func reconfigureRetention(historyRetention: HistoryRetention, eventDebounceMinutes: Double) {
        queue.sync {
            sampleRetentionSeconds = TimeInterval(max(1, historyRetention.rawMinutes)) * 60
            aggregateRetentionHours = max(1, historyRetention.aggregateHours)
            eventDebounceSeconds = max(0, eventDebounceMinutes * 60)
            guard let db else { return }
            pruneIfNeeded(on: db)
        }
    }

    public func append(_ record: TelemetrySampleRecord) {
        queue.sync {
            guard let db else { return }
            pruneIfNeeded(on: db)
            insertSample(db: db, record)
            updateHourlyAggregate(db: db, record)
        }
    }

    public func fetchRecent(limit: Int) -> [TelemetrySampleRecord] {
        return queue.sync {
            guard let db else { return [] }
            return querySamples(db: db, limit: limit)
        }
    }

    public func appendEvent(_ event: TelemetryEventRecord) {
        queue.sync {
            guard let db else { return }
            pruneIfNeeded(on: db)
            guard shouldRecord(event: event, db: db) else { return }
            insertEvent(db: db, event)
        }
    }

    public func fetchRecentEvents(limit: Int) -> [TelemetryEventRecord] {
        return queue.sync {
            guard let db else { return [] }
            return queryEvents(db: db, limit: limit)
        }
    }

    public func fetchRecentAggregates(limit: Int) -> [TelemetryAggregateRecord] {
        return queue.sync {
            guard let db else { return [] }
            return queryAggregates(db: db, limit: limit)
        }
    }

    public func clear() {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "DELETE FROM telemetry_sample_records;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM telemetry_sample_aggregates;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM telemetry_events;", nil, nil, nil)
        }
    }

    deinit {
        sqlite3_close(db)
    }

    private func setupDatabase() {
        let fm = FileManager.default
        let parent = snapshotURL.deletingLastPathComponent()
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)

        guard sqlite3_open(snapshotURL.path, &db) == SQLITE_OK else {
            db = nil
            return
        }

        // Limit in-process SQLite page cache to ~200 KB (default is ~8 MB).
        sqlite3_exec(db, "PRAGMA cache_size = -50;", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA journal_mode = WAL;", nil, nil, nil)

        let schema = """
            CREATE TABLE IF NOT EXISTS telemetry_sample_records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                thermal_score REAL NOT NULL,
                source TEXT NOT NULL,
                reason TEXT NOT NULL,
                target_rpm INTEGER NOT NULL DEFAULT 0,
                current_rpm INTEGER NOT NULL DEFAULT 0
            );
            CREATE INDEX IF NOT EXISTS idx_sample_timestamp ON telemetry_sample_records(timestamp);

            CREATE TABLE IF NOT EXISTS telemetry_sample_aggregates (
                hour_bucket INTEGER PRIMARY KEY,
                average REAL NOT NULL,
                sample_count INTEGER NOT NULL,
                last_seen REAL NOT NULL
            );

            CREATE TABLE IF NOT EXISTS telemetry_events (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                timestamp REAL NOT NULL,
                state TEXT NOT NULL,
                level TEXT NOT NULL,
                reason TEXT NOT NULL,
                payload TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS idx_event_timestamp ON telemetry_events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_event_reason ON telemetry_events(reason, level, timestamp);
        """

        _ = schema.split(separator: ";").map(String.init).filter { !$0.isEmpty }.map {
            sqlite3_exec(db, $0 + ";", nil, nil, nil)
        }
        sqlite3_exec(db, "ALTER TABLE telemetry_sample_records ADD COLUMN target_rpm INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
        sqlite3_exec(db, "ALTER TABLE telemetry_sample_records ADD COLUMN current_rpm INTEGER NOT NULL DEFAULT 0;", nil, nil, nil)
    }

    private func pruneIfNeeded(on db: OpaquePointer) {
        let now = Date().timeIntervalSince1970
        let sampleCutoff = now - sampleRetentionSeconds
        let aggregateCutoff = now - TimeInterval(aggregateRetentionHours * 3600)
        let eventCutoff = now - TimeInterval(eventRetentionHours * 3600)

        _ = sqlite3_exec(db, "DELETE FROM telemetry_sample_records WHERE timestamp < \(sampleCutoff);", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM telemetry_sample_aggregates WHERE last_seen < \(aggregateCutoff);", nil, nil, nil)
        _ = sqlite3_exec(db, "DELETE FROM telemetry_events WHERE timestamp < \(eventCutoff);", nil, nil, nil)
    }

    private func shouldRecord(event: TelemetryEventRecord, db: OpaquePointer) -> Bool {
        if eventDebounceSeconds <= 0 { return true }
        if event.level != "warn" && event.level != "error" {
            return true
        }

        let query = "SELECT timestamp FROM telemetry_events WHERE reason = ?1 AND (level = 'warn' OR level = 'error') ORDER BY timestamp DESC LIMIT 1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            return true
        }

        sqlite3_bind_text(statement, 1, (event.reason as NSString).utf8String, -1, nil)
        let hasRow = sqlite3_step(statement) == SQLITE_ROW
        guard hasRow else {
            return true
        }
        let lastTime = sqlite3_column_double(statement, 0)
        let elapsed = Date().timeIntervalSince1970 - lastTime
        return elapsed >= eventDebounceSeconds
    }

    private func insertSample(db: OpaquePointer, _ record: TelemetrySampleRecord) {
        let insert = "INSERT INTO telemetry_sample_records (timestamp, thermal_score, source, reason, target_rpm, current_rpm) VALUES (?1, ?2, ?3, ?4, ?5, ?6);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_double(statement, 1, record.timestamp.timeIntervalSince1970)
        sqlite3_bind_double(statement, 2, record.thermalScore)
        sqlite3_bind_text(statement, 3, (record.source as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (record.reason as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 5, Int32(record.targetRPM))
        sqlite3_bind_int(statement, 6, Int32(record.currentRPM))
        _ = sqlite3_step(statement)
    }

    private func updateHourlyAggregate(db: OpaquePointer, _ record: TelemetrySampleRecord) {
        let hourBucket = Int64(floor(record.timestamp.timeIntervalSince1970 / 3600))
        let now = record.timestamp.timeIntervalSince1970

        let fetch = "SELECT average, sample_count FROM telemetry_sample_aggregates WHERE hour_bucket = ?1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, fetch, -1, &statement, nil) == SQLITE_OK else {
            return
        }
        sqlite3_bind_int64(statement, 1, hourBucket)
            if sqlite3_step(statement) == SQLITE_ROW {
                let prevAverage = sqlite3_column_double(statement, 0)
                let prevCount = Double(sqlite3_column_int(statement, 1))
                let total = prevAverage * prevCount + record.thermalScore
                let nextCount = prevCount + 1
                let nextAverage = total / max(1, nextCount)
                let update = "UPDATE telemetry_sample_aggregates SET average = ?2, sample_count = ?3, last_seen = ?4 WHERE hour_bucket = ?1;"
                var updateStmt: OpaquePointer?
                defer { sqlite3_finalize(updateStmt) }
                if sqlite3_prepare_v2(db, update, -1, &updateStmt, nil) == SQLITE_OK {
                    sqlite3_bind_int64(updateStmt, 1, hourBucket)
                    sqlite3_bind_double(updateStmt, 2, nextAverage)
                    sqlite3_bind_double(updateStmt, 3, nextCount)
                    sqlite3_bind_double(updateStmt, 4, now)
                    _ = sqlite3_step(updateStmt)
                }
        } else {
            let insert = "INSERT INTO telemetry_sample_aggregates (hour_bucket, average, sample_count, last_seen) VALUES (?1, ?2, ?3, ?4);"
            var insertStmt: OpaquePointer?
            defer { sqlite3_finalize(insertStmt) }
            guard sqlite3_prepare_v2(db, insert, -1, &insertStmt, nil) == SQLITE_OK else {
                return
            }
            sqlite3_bind_int64(insertStmt, 1, hourBucket)
            sqlite3_bind_double(insertStmt, 2, record.thermalScore)
            sqlite3_bind_int64(insertStmt, 3, 1)
            sqlite3_bind_double(insertStmt, 4, now)
            _ = sqlite3_step(insertStmt)
        }
    }

    private func insertEvent(db: OpaquePointer, _ event: TelemetryEventRecord) {
        let payloadData = (try? JSONEncoder().encode(event.payload)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let insert = "INSERT INTO telemetry_events (timestamp, state, level, reason, payload) VALUES (?1, ?2, ?3, ?4, ?5);"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, insert, -1, &statement, nil) == SQLITE_OK else {
            return
        }

        sqlite3_bind_double(statement, 1, event.timestamp.timeIntervalSince1970)
        sqlite3_bind_text(statement, 2, (event.state as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (event.level as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, (event.reason as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 5, (payloadData as NSString).utf8String, -1, nil)
        _ = sqlite3_step(statement)
    }

    private func querySamples(db: OpaquePointer, limit: Int) -> [TelemetrySampleRecord] {
        let safeLimit = max(1, limit)
        let select = "SELECT timestamp, thermal_score, source, reason, target_rpm, current_rpm FROM telemetry_sample_records ORDER BY timestamp DESC LIMIT ?1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, select, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var result: [TelemetrySampleRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let score = sqlite3_column_double(statement, 1)
            let source = String(cString: sqlite3_column_text(statement, 2))
            let reason = String(cString: sqlite3_column_text(statement, 3))
            let targetRPM = Int(sqlite3_column_int(statement, 4))
            let currentRPM = Int(sqlite3_column_int(statement, 5))
            result.append(TelemetrySampleRecord(thermalScore: score, source: source, reason: reason, targetRPM: targetRPM, currentRPM: currentRPM, timestamp: timestamp))
        }

        return Array(result.reversed())
    }

    private func queryAggregates(db: OpaquePointer, limit: Int) -> [TelemetryAggregateRecord] {
        let safeLimit = max(1, limit)
        let select = "SELECT hour_bucket, average, sample_count, last_seen FROM telemetry_sample_aggregates ORDER BY hour_bucket DESC LIMIT ?1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, select, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var result: [TelemetryAggregateRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let hourBucket = sqlite3_column_int64(statement, 0)
            let average = sqlite3_column_double(statement, 1)
            let sampleCount = Int(sqlite3_column_int(statement, 2))
            let lastSeen = sqlite3_column_double(statement, 3)
            result.append(
                TelemetryAggregateRecord(
                    hourBucket: hourBucket,
                    average: average,
                    sampleCount: sampleCount,
                    lastSeen: Date(timeIntervalSince1970: lastSeen)
                )
            )
        }

        return Array(result.reversed())
    }

    private func queryEvents(db: OpaquePointer, limit: Int) -> [TelemetryEventRecord] {
        let safeLimit = max(1, limit)
        let select = "SELECT timestamp, state, level, reason, payload FROM telemetry_events ORDER BY timestamp DESC LIMIT ?1;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        guard sqlite3_prepare_v2(db, select, -1, &statement, nil) == SQLITE_OK else {
            return []
        }
        sqlite3_bind_int(statement, 1, Int32(safeLimit))

        var result: [TelemetryEventRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
            let state = String(cString: sqlite3_column_text(statement, 1))
            let level = String(cString: sqlite3_column_text(statement, 2))
            let reason = String(cString: sqlite3_column_text(statement, 3))
            let payloadText = String(cString: sqlite3_column_text(statement, 4))
            let payload = (try? JSONDecoder().decode([String: String].self, from: Data(payloadText.utf8))) ?? [:]
            result.append(TelemetryEventRecord(state: state, level: level, reason: reason, payload: payload, timestamp: timestamp))
        }

        return Array(result.reversed())
    }

    private static let defaultSnapshotURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .libraryDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        return base.appendingPathComponent("Application Support/MFanControl/telemetry.sqlite")
    }()
}
