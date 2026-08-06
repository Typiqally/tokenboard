import CSQLite
import Foundation
import Security

public enum LedgerError: Error, Equatable {
    case notMigrated
    case quantityOverflow
    case corruptData(String)
    case randomSaltGenerationFailed(Int32)
}

public enum LedgerValidationError: Error, Equatable, Sendable {
    case invalidObservedModelID
    case invalidCheckpointFingerprint
    case invalidLastUsageIdentityHash
    case invalidLastCommittedLineHash
    case invalidSkippedSourceFingerprint
    case invalidSkippedRecordHash
    case invalidSkippedReason
    case invalidAdapterStateKey
    case invalidAdapterStateModelID
}

public actor SQLiteLedger: LedgerStore {
    private var connection: SQLiteConnection?
    private let backupDirectory: URL
    private var privacyHasher: PrivacyHasher?

    public init(databaseURL: URL, backupDirectory: URL) throws {
        connection = try SQLiteConnection(url: databaseURL)
        self.backupDirectory = backupDirectory
    }

    public func migrate() throws {
        let connection = try requiredConnection()
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backupDirectory,
            migrations: Migrations.all
        ).migrate()
        privacyHasher = try loadOrCreatePrivacyHasher(using: connection)
    }

    public func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) throws {
        let connection = try requiredConnection()
        try validateStorageBoundary(usage: usage, skipped: skipped, checkpoint: checkpoint)
        let groupedUsage = try grouped(usage, calendar: calendar)
        let checkpointMetrics = try encodedJSON(checkpoint.cumulativeMetrics)
        let adapterState = try encodedJSON(checkpoint.adapterState)

        try connection.transaction {
            for row in groupedUsage {
                try upsertUsage(row, using: connection)
            }
            for record in skipped {
                try insertSkippedRecord(record, using: connection)
            }
            try upsertCheckpoint(
                checkpoint,
                cumulativeMetrics: checkpointMetrics,
                adapterState: adapterState,
                using: connection
            )
        }
    }

    public func usageRows(in interval: DateInterval?, calendar: Calendar) throws -> [DailyUsageRow] {
        let connection = try requiredConnection()
        let statement: OpaquePointer
        if let interval {
            let firstDay = LocalDay(date: interval.start, calendar: calendar)
            guard let lastDate = calendar.date(byAdding: .day, value: -1, to: interval.end) else {
                throw LedgerError.corruptData("could not calculate interval end day")
            }
            let lastDay = LocalDay(date: lastDate, calendar: calendar)
            statement = try prepare(
                """
                SELECT local_day, time_zone, provider, observed_model_id, metric, aggregation, quantity
                FROM daily_usage
                WHERE local_day >= ? AND local_day <= ?
                ORDER BY local_day, time_zone, provider, observed_model_id, metric;
                """,
                using: connection
            )
            try bind(firstDay.value, to: statement, at: 1, using: connection)
            try bind(lastDay.value, to: statement, at: 2, using: connection)
        } else {
            statement = try prepare(
                """
                SELECT local_day, time_zone, provider, observed_model_id, metric, aggregation, quantity
                FROM daily_usage
                ORDER BY local_day, time_zone, provider, observed_model_id, metric;
                """,
                using: connection
            )
        }
        defer { sqlite3_finalize(statement) }

        var rows: [DailyUsageRow] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(try usageRow(from: statement))
            case SQLITE_DONE:
                return rows
            default:
                throw failure(result, using: connection)
            }
        }
    }

    public func checkpoint(for fingerprint: String) throws -> SourceCheckpoint? {
        let connection = try requiredConnection()
        let statement = try prepare(
            """
            SELECT fingerprint, provider, parser_version, byte_offset, file_size, modification_time,
                   last_usage_identity_hash, last_committed_line_hash, cumulative_metrics_json, adapter_state_json
            FROM source_checkpoints WHERE fingerprint = ?;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(fingerprint, to: statement, at: 1, using: connection)

        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return try decodedCheckpoint(from: statement)
        case SQLITE_DONE:
            return nil
        default:
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }
    }

    public func sourceFingerprint(provider: Provider, stableID: String) throws -> String {
        try requiredPrivacyHasher().fingerprint(provider: provider, stableID: stableID)
    }

    public func recordIdentityHash(_ value: String) throws -> String {
        try requiredPrivacyHasher().recordHash(value)
    }

    private func requiredConnection() throws -> SQLiteConnection {
        guard let connection else { throw LedgerError.notMigrated }
        return connection
    }

    private func requiredPrivacyHasher() throws -> PrivacyHasher {
        guard let privacyHasher else { throw LedgerError.notMigrated }
        return privacyHasher
    }

    private func loadOrCreatePrivacyHasher(using connection: SQLiteConnection) throws -> PrivacyHasher {
        if let salt = try privacySalt(using: connection) {
            return PrivacyHasher(salt: salt)
        }

        var storedSalt: Data?
        try connection.transaction {
            if let salt = try privacySalt(using: connection) {
                storedSalt = salt
            } else {
                let salt = try randomSalt()
                let insert = try prepare(
                    "INSERT INTO app_metadata(key, value) VALUES('privacy_salt', ?);",
                    using: connection
                )
                defer { sqlite3_finalize(insert) }
                try bind(salt, to: insert, at: 1, using: connection)
                try stepDone(insert, using: connection)
                storedSalt = salt
            }
        }
        guard let storedSalt else { throw LedgerError.corruptData("privacy salt is missing") }
        return PrivacyHasher(salt: storedSalt)
    }

    private func privacySalt(using connection: SQLiteConnection) throws -> Data? {
        let statement = try prepare("SELECT value FROM app_metadata WHERE key = 'privacy_salt';", using: connection)
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            guard let bytes = sqlite3_column_blob(statement, 0) else {
                throw LedgerError.corruptData("privacy salt is missing")
            }
            let length = Int(sqlite3_column_bytes(statement, 0))
            guard length == 32 else { throw LedgerError.corruptData("privacy salt has invalid length") }
            return Data(bytes: bytes, count: length)
        case SQLITE_DONE:
            return nil
        default:
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }
    }

    private func randomSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw LedgerError.randomSaltGenerationFailed(result) }
        return Data(bytes)
    }

    private func validateStorageBoundary(
        usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint
    ) throws {
        for entry in usage where !isContentSafeModelID(entry.observedModelID) {
            throw LedgerValidationError.invalidObservedModelID
        }
        guard isOpaqueDigest(checkpoint.fingerprint) else {
            throw LedgerValidationError.invalidCheckpointFingerprint
        }
        if let hash = checkpoint.lastUsageIdentityHash, !isOpaqueDigest(hash) {
            throw LedgerValidationError.invalidLastUsageIdentityHash
        }
        if let hash = checkpoint.lastCommittedLineHash, !isOpaqueDigest(hash) {
            throw LedgerValidationError.invalidLastCommittedLineHash
        }
        for record in skipped {
            guard isOpaqueDigest(record.sourceFingerprint) else {
                throw LedgerValidationError.invalidSkippedSourceFingerprint
            }
            guard isOpaqueDigest(record.recordHash) else {
                throw LedgerValidationError.invalidSkippedRecordHash
            }
            guard Self.allowedSkippedReasons.contains(record.reason) else {
                throw LedgerValidationError.invalidSkippedReason
            }
        }
        for (key, value) in checkpoint.adapterState {
            guard key == "current_model" else {
                throw LedgerValidationError.invalidAdapterStateKey
            }
            guard isContentSafeModelID(value) else {
                throw LedgerValidationError.invalidAdapterStateModelID
            }
        }
    }

    private func isOpaqueDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func isContentSafeModelID(_ value: String) -> Bool {
        if value == "<synthetic>" {
            return true
        }
        guard (1...256).contains(value.utf8.count), let first = value.utf8.first else {
            return false
        }
        return Self.alphanumericModelIDBytes.contains(first)
            && value.utf8.allSatisfy { Self.allowedModelIDBytes.contains($0) }
    }

    private func grouped(_ usage: [NormalizedUsage], calendar: Calendar) throws -> [DailyUsageRow] {
        var quantities: [UsageKey: Int64] = [:]
        for entry in usage {
            let localDay = LocalDay(date: entry.timestamp, calendar: calendar)
            for (metric, quantity) in entry.metrics {
                let key = UsageKey(
                    localDay: localDay,
                    provider: entry.provider,
                    observedModelID: entry.observedModelID,
                    metric: metric
                )
                let current = quantities[key, default: 0]
                let (total, overflow) = current.addingReportingOverflow(quantity)
                guard !overflow else { throw LedgerError.quantityOverflow }
                quantities[key] = total
            }
        }
        return quantities.map { key, quantity in
            DailyUsageRow(
                localDay: key.localDay,
                provider: key.provider,
                observedModelID: key.observedModelID,
                metric: key.metric,
                aggregation: key.metric.aggregation,
                quantity: quantity
            )
        }
    }

    private func upsertUsage(_ row: DailyUsageRow, using connection: SQLiteConnection) throws {
        let statement = try prepare(
            """
            INSERT INTO daily_usage(local_day, time_zone, provider, observed_model_id, metric, aggregation, quantity)
            VALUES(?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(local_day, time_zone, provider, observed_model_id, metric)
            DO UPDATE SET quantity = quantity + excluded.quantity;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(row.localDay.value, to: statement, at: 1, using: connection)
        try bind(row.localDay.timeZoneIdentifier, to: statement, at: 2, using: connection)
        try bind(row.provider.rawValue, to: statement, at: 3, using: connection)
        try bind(row.observedModelID, to: statement, at: 4, using: connection)
        try bind(row.metric.rawValue, to: statement, at: 5, using: connection)
        try bind(row.aggregation.rawValue, to: statement, at: 6, using: connection)
        try bind(row.quantity, to: statement, at: 7, using: connection)
        try stepDone(statement, using: connection)
    }

    private func insertSkippedRecord(_ record: SkippedRecord, using connection: SQLiteConnection) throws {
        let statement = try prepare(
            """
            INSERT OR IGNORE INTO skipped_records(
              source_fingerprint, byte_offset, record_hash, parser_version, reason
            ) VALUES(?, ?, ?, ?, ?);
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(record.sourceFingerprint, to: statement, at: 1, using: connection)
        try bind(record.byteOffset, to: statement, at: 2, using: connection)
        try bind(record.recordHash, to: statement, at: 3, using: connection)
        try bind(Int64(record.parserVersion), to: statement, at: 4, using: connection)
        try bind(record.reason, to: statement, at: 5, using: connection)
        try stepDone(statement, using: connection)
    }

    private func upsertCheckpoint(
        _ checkpoint: SourceCheckpoint,
        cumulativeMetrics: String,
        adapterState: String,
        using connection: SQLiteConnection
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO source_checkpoints(
              fingerprint, provider, parser_version, byte_offset, file_size,
              modification_time, last_usage_identity_hash, last_committed_line_hash,
              cumulative_metrics_json, adapter_state_json
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(fingerprint) DO UPDATE SET
              parser_version = excluded.parser_version,
              byte_offset = excluded.byte_offset,
              file_size = excluded.file_size,
              modification_time = excluded.modification_time,
              last_usage_identity_hash = excluded.last_usage_identity_hash,
              last_committed_line_hash = excluded.last_committed_line_hash,
              cumulative_metrics_json = excluded.cumulative_metrics_json,
              adapter_state_json = excluded.adapter_state_json;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(checkpoint.fingerprint, to: statement, at: 1, using: connection)
        try bind(checkpoint.provider.rawValue, to: statement, at: 2, using: connection)
        try bind(Int64(checkpoint.parserVersion), to: statement, at: 3, using: connection)
        try bind(checkpoint.byteOffset, to: statement, at: 4, using: connection)
        try bind(checkpoint.fileSize, to: statement, at: 5, using: connection)
        try bind(checkpoint.modificationTime.map(encodeDate), to: statement, at: 6, using: connection)
        try bind(checkpoint.lastUsageIdentityHash, to: statement, at: 7, using: connection)
        try bind(checkpoint.lastCommittedLineHash, to: statement, at: 8, using: connection)
        try bind(cumulativeMetrics, to: statement, at: 9, using: connection)
        try bind(adapterState, to: statement, at: 10, using: connection)
        try stepDone(statement, using: connection)
    }

    private func usageRow(from statement: OpaquePointer) throws -> DailyUsageRow {
        let localDay = try requiredText(statement, at: 0)
        let timeZone = try requiredText(statement, at: 1)
        guard let provider = Provider(rawValue: try requiredText(statement, at: 2)),
              let metric = UsageMetric(rawValue: try requiredText(statement, at: 4)),
              let aggregation = MetricAggregation(rawValue: try requiredText(statement, at: 5)) else {
            throw LedgerError.corruptData("daily usage enum value is invalid")
        }
        return DailyUsageRow(
            localDay: try decodedLocalDay(value: localDay, timeZoneIdentifier: timeZone),
            provider: provider,
            observedModelID: try requiredText(statement, at: 3),
            metric: metric,
            aggregation: aggregation,
            quantity: sqlite3_column_int64(statement, 6)
        )
    }

    private func decodedCheckpoint(from statement: OpaquePointer) throws -> SourceCheckpoint {
        guard let provider = Provider(rawValue: try requiredText(statement, at: 1)) else {
            throw LedgerError.corruptData("checkpoint provider is invalid")
        }
        let metrics: [UsageMetric: Int64] = try decodedJSON(try requiredText(statement, at: 8))
        let adapterState: [String: String] = try decodedJSON(try requiredText(statement, at: 9))
        return SourceCheckpoint(
            fingerprint: try requiredText(statement, at: 0),
            provider: provider,
            parserVersion: Int(sqlite3_column_int64(statement, 2)),
            byteOffset: sqlite3_column_int64(statement, 3),
            fileSize: sqlite3_column_int64(statement, 4),
            modificationTime: try optionalText(statement, at: 5).map(decodeDate),
            lastUsageIdentityHash: try optionalText(statement, at: 6),
            lastCommittedLineHash: try optionalText(statement, at: 7),
            cumulativeMetrics: metrics,
            adapterState: adapterState
        )
    }

    private func decodedLocalDay(value: String, timeZoneIdentifier: String) throws -> LocalDay {
        let components = value.split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 3,
              let year = Int(components[0]),
              let month = Int(components[1]),
              let day = Int(components[2]),
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw LedgerError.corruptData("daily usage local day is invalid")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else {
            throw LedgerError.corruptData("daily usage local day is invalid")
        }
        return LocalDay(date: date, calendar: calendar)
    }

    private func encodedJSON<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard let string = String(data: data, encoding: .utf8) else {
            throw LedgerError.corruptData("could not encode JSON as UTF-8")
        }
        return string
    }

    private func decodedJSON<Value: Decodable>(_ string: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(string.utf8))
    }

    private func encodeDate(_ date: Date) -> String {
        String(date.timeIntervalSince1970)
    }

    private func decodeDate(_ value: String) throws -> Date {
        guard let timestamp = TimeInterval(value) else {
            throw LedgerError.corruptData("checkpoint modification time is invalid")
        }
        return Date(timeIntervalSince1970: timestamp)
    }

    private func prepare(_ sql: String, using connection: SQLiteConnection) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection.handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw failure(result, using: connection) }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws {
        try sqliteBindText(value, to: statement, at: index, using: connection)
    }

    private func bind(_ value: Int64, to statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else { throw failure(result, using: connection) }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { throw failure(result, using: connection) }
    }

    private func bind(_ value: String?, to statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws {
        guard let value else {
            let result = sqlite3_bind_null(statement, index)
            guard result == SQLITE_OK else { throw failure(result, using: connection) }
            return
        }
        try bind(value, to: statement, at: index, using: connection)
    }

    private func stepDone(_ statement: OpaquePointer, using connection: SQLiteConnection) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw failure(result, using: connection) }
    }

    private func requiredText(_ statement: OpaquePointer, at index: Int32) throws -> String {
        try sqliteText(statement, at: index, using: try requiredConnection())
    }

    private func optionalText(_ statement: OpaquePointer, at index: Int32) throws -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return try requiredText(statement, at: index)
    }

    private func failure(_ code: Int32, using connection: SQLiteConnection) -> SQLiteFailure {
        SQLiteFailure(code: code, message: String(cString: sqlite3_errmsg(connection.handle)))
    }
}

private struct UsageKey: Hashable {
    let localDay: LocalDay
    let provider: Provider
    let observedModelID: String
    let metric: UsageMetric
}

private extension SQLiteLedger {
    static let allowedSkippedReasons: Set<String> = [
        "malformed_record",
        "missing_model",
        "missing_source_identity",
        "inconsistent_subtotals",
        "inconsistent_total"
    ]

    static let allowedModelIDBytes: Set<UInt8> = {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-"
        return Set(allowed.utf8)
    }()

    static let alphanumericModelIDBytes: Set<UInt8> = {
        let allowed = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        return Set(allowed.utf8)
    }()
}
