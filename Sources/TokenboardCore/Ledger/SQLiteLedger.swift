import CSQLite
import Foundation
import Security

public enum LedgerError: Error, Equatable {
    case notMigrated
    case connectionClosed
    case quantityOverflow
    case corruptData(String)
    case integrityCheckFailed(String)
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

public enum PricingLedgerError: Error, Equatable, Sendable {
    case canonicalContentMismatch
    case semanticConflict(String)
    case invalidImportMetadata
}

public actor SQLiteLedger: LedgerStore {
    private var connection: SQLiteConnection?
    private let backupDirectory: URL
    private var privacyHasher: PrivacyHasher?
    private var isClosed = false

    public init(databaseURL: URL, backupDirectory: URL) throws {
        connection = try SQLiteConnection(url: databaseURL)
        self.backupDirectory = backupDirectory
    }

    init(recoveryConnection: SQLiteConnection, backupDirectory: URL) {
        connection = recoveryConnection
        self.backupDirectory = backupDirectory
    }

    public func migrate() throws {
        try migrate(createPreMigrationBackup: true)
    }

    func migrateForRecovery() throws {
        try migrate(createPreMigrationBackup: false)
    }

    private func migrate(createPreMigrationBackup: Bool) throws {
        let connection = try requiredConnection()
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backupDirectory,
            migrations: Migrations.all
        ).migrate(createPreMigrationBackup: createPreMigrationBackup)
        privacyHasher = try loadOrCreatePrivacyHasher(using: connection)
    }

    public func integrityCheck() throws {
        let rows = try requiredConnection().queryStrings("PRAGMA quick_check;")
        guard rows == ["ok"] else {
            throw LedgerError.integrityCheckFailed(rows.joined(separator: "; "))
        }
    }

    public func shutdown() throws {
        guard !isClosed else { return }
        guard let openConnection = connection else {
            throw LedgerError.connectionClosed
        }
        try openConnection.checkpointWAL()
        try openConnection.close()
        privacyHasher = nil
        connection = nil
        isClosed = true
    }

    func writeSerializedRecoveryDatabase(to descriptor: Int32, maximumBytes: Int) throws {
        try requiredConnection().writeSerializedDatabase(
            to: descriptor,
            maximumBytes: maximumBytes
        )
    }

    public func skippedRecordCount() throws -> Int {
        let connection = try requiredConnection()
        let statement = try prepare(
            "SELECT COUNT(*) FROM skipped_records;",
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }
        let value = sqlite3_column_int64(statement, 0)
        guard value >= 0, let count = Int(exactly: value) else {
            throw LedgerError.corruptData("skipped-record count is invalid")
        }
        return count
    }

    public func skippedRecordCountsByProvider() throws -> [Provider: Int] {
        let connection = try requiredConnection()
        let statement = try prepare(
            """
            SELECT source_checkpoints.provider, COUNT(*)
            FROM skipped_records
            JOIN source_checkpoints
              ON source_checkpoints.fingerprint = skipped_records.source_fingerprint
            GROUP BY source_checkpoints.provider
            ORDER BY source_checkpoints.provider;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        var counts: [Provider: Int] = [:]
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return counts }
            guard result == SQLITE_ROW else {
                throw failure(result, using: connection)
            }
            let rawProvider = try sqliteText(statement, at: 0, using: connection)
            guard let provider = Provider(rawValue: rawProvider) else {
                throw LedgerError.corruptData("skipped-record provider is invalid")
            }
            let rawCount = sqlite3_column_int64(statement, 1)
            guard rawCount >= 0, let count = Int(exactly: rawCount) else {
                throw LedgerError.corruptData("skipped-record provider count is invalid")
            }
            counts[provider] = count
        }
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
        let groupedHourlyUsage = try groupedHourly(usage, calendar: calendar)
        let checkpointMetrics = try encodedJSON(checkpoint.cumulativeMetrics)
        let adapterState = try encodedJSON(checkpoint.adapterState)

        try connection.beginTransaction()
        do {
            for row in groupedUsage {
                try upsertUsage(row, using: connection)
            }
            for row in groupedHourlyUsage {
                try upsertHourlyUsage(row, using: connection)
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
            try connection.commitTransaction()
        } catch {
            try? connection.rollbackTransaction()
            throw error
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

    public func lifetimeAdditiveTokenTotal() throws -> Int64 {
        let connection = try requiredConnection()
        let statement = try prepare(
            "SELECT COALESCE(SUM(quantity), 0) FROM daily_usage WHERE aggregation = ?;",
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(MetricAggregation.additive.rawValue, to: statement, at: 1, using: connection)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw failure(result, using: connection)
        }
        let total = sqlite3_column_int64(statement, 0)
        guard total >= 0 else {
            throw LedgerError.corruptData("lifetime additive token total is negative")
        }
        return total
    }

    public func hourlyUsageRows(
        in interval: DateInterval?,
        calendar: Calendar
    ) async throws -> [HourlyUsageRow] {
        let connection = try requiredConnection()
        let statement: OpaquePointer
        if let interval {
            statement = try prepare(
                """
                SELECT hour_start, local_day, time_zone, provider, observed_model_id,
                       metric, aggregation, quantity
                FROM hourly_usage
                WHERE hour_start >= ? AND hour_start < ?
                ORDER BY hour_start, time_zone, provider, observed_model_id, metric;
                """,
                using: connection
            )
            try bind(epochSeconds(interval.start), to: statement, at: 1, using: connection)
            try bind(epochSeconds(interval.end), to: statement, at: 2, using: connection)
        } else {
            statement = try prepare(
                """
                SELECT hour_start, local_day, time_zone, provider, observed_model_id,
                       metric, aggregation, quantity
                FROM hourly_usage
                ORDER BY hour_start, time_zone, provider, observed_model_id, metric;
                """,
                using: connection
            )
        }
        defer { sqlite3_finalize(statement) }

        var rows: [HourlyUsageRow] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                rows.append(try hourlyUsageRow(from: statement))
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

    public func pricingSnapshot() throws -> PricingSnapshot {
        let connection = try requiredConnection()
        let catalogIDs = try readCatalogIDs(using: connection)
        let rates = try readPriceRates(using: connection)
        let aliases = try readModelAliases(using: connection)
        let exchangeRateSnapshots = try readExchangeRateSnapshots(using: connection)
        return PricingSnapshot(
            catalogIDs: catalogIDs,
            rates: rates,
            aliases: aliases,
            exchangeRateSnapshots: exchangeRateSnapshots
        )
    }

    public func latestAppliedPricingCatalogJSON() throws -> Data? {
        let connection = try requiredConnection()
        let statement = try prepare(
            """
            SELECT canonical_json
            FROM catalog_imports AS imports
            JOIN active_catalog_import AS active
              ON active.import_id = imports.import_id
            WHERE active.singleton = 1
            LIMIT 1;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            return Data(try requiredText(statement, at: 0).utf8)
        case SQLITE_DONE:
            return nil
        default:
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }
    }

    public func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        let connection = try requiredConnection()
        guard canonicalJSON == catalog.canonicalJSON,
              let canonicalString = String(data: canonicalJSON, encoding: .utf8) else {
            throw PricingLedgerError.canonicalContentMismatch
        }
        guard PricingImportMetadata.allowedOrigins.contains(origin),
              PricingImportMetadata.allowedValidationSummaries.contains(validationSummary) else {
            throw PricingLedgerError.invalidImportMetadata
        }

        try connection.beginTransaction()
        do {
            try connection.execute("""
            DELETE FROM fx_rates;
            DELETE FROM model_aliases;
            DELETE FROM price_rates;
            """)
            for model in catalog.models {
                for alias in model.aliases {
                    try insertAliasIfNew(alias, model: model, catalogID: catalog.catalogID, using: connection)
                }
                for rate in model.rates {
                    for (metric, price) in rate.prices {
                        try insertRateIfNew(
                            rate,
                            metric: metric,
                            price: price,
                            model: model,
                            catalogID: catalog.catalogID,
                            using: connection
                        )
                    }
                }
            }
            if let exchangeRates = catalog.exchangeRates {
                try insertExchangeRates(
                    exchangeRates,
                    catalogID: catalog.catalogID,
                    using: connection
                )
            }
            let importID = try insertCatalogImport(
                catalog,
                canonicalJSON: canonicalString,
                origin: origin,
                validationSummary: validationSummary,
                using: connection
            )
            try selectActiveCatalogImport(importID, using: connection)
            try connection.commitTransaction()
        } catch {
            try? connection.rollbackTransaction()
            throw error
        }
    }

    private func requiredConnection() throws -> SQLiteConnection {
        guard !isClosed else { throw LedgerError.connectionClosed }
        guard let connection else { throw LedgerError.notMigrated }
        return connection
    }

    private func requiredPrivacyHasher() throws -> PrivacyHasher {
        guard !isClosed else { throw LedgerError.connectionClosed }
        guard let privacyHasher else { throw LedgerError.notMigrated }
        return privacyHasher
    }

    private func readCatalogIDs(using connection: SQLiteConnection) throws -> [String] {
        let statement = try prepare(
            """
            SELECT imports.catalog_id
            FROM active_catalog_import AS active
            JOIN catalog_imports AS imports ON imports.import_id = active.import_id
            WHERE active.singleton = 1;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                values.append(try requiredText(statement, at: 0))
            case SQLITE_DONE:
                return values
            default:
                throw failure(sqlite3_errcode(connection.handle), using: connection)
            }
        }
    }

    private func readPriceRates(using connection: SQLiteConnection) throws -> [StoredPriceRate] {
        let statement = try prepare(
            """
            SELECT provider, canonical_model_id, metric, usd_per_million, effective_from,
                   effective_to, provenance_url, verified_at
            FROM price_rates
            ORDER BY provider, canonical_model_id, metric, effective_from;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        var values: [StoredPriceRate] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let storedPrice = try requiredText(statement, at: 3)
                let storedProvenance = try requiredText(statement, at: 6)
                guard let provider = Provider(rawValue: try requiredText(statement, at: 0)),
                      let metric = UsageMetric(rawValue: try requiredText(statement, at: 2)),
                      let decimal = Decimal(
                        string: storedPrice,
                        locale: Locale(identifier: "en_US_POSIX")
                      ),
                      !decimal.isNaN,
                      decimal >= 0,
                      decimal <= 100_000,
                      DecimalString(decimal: decimal).rawValue == storedPrice,
                      let provenanceComponents = URLComponents(string: storedProvenance),
                      provenanceComponents.scheme?.lowercased() == "https",
                      provenanceComponents.host != nil,
                      let provenanceURL = provenanceComponents.url else {
                    throw LedgerError.corruptData("stored pricing rate is invalid")
                }
                values.append(StoredPriceRate(
                    provider: provider,
                    canonicalModelID: try requiredText(statement, at: 1),
                    metric: metric,
                    usdPerMillion: decimal,
                    effectiveFrom: try requiredText(statement, at: 4),
                    effectiveTo: try optionalText(statement, at: 5),
                    provenanceURL: provenanceURL,
                    verifiedAt: try requiredText(statement, at: 7)
                ))
            case SQLITE_DONE:
                return values
            default:
                throw failure(sqlite3_errcode(connection.handle), using: connection)
            }
        }
    }

    private func readModelAliases(using connection: SQLiteConnection) throws -> [StoredModelAlias] {
        let statement = try prepare(
            """
            SELECT provider, observed_model_id, canonical_model_id, effective_from, effective_to
            FROM model_aliases
            ORDER BY provider, observed_model_id, effective_from;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        var values: [StoredModelAlias] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let provider = Provider(rawValue: try requiredText(statement, at: 0)) else {
                    throw LedgerError.corruptData("stored model alias provider is invalid")
                }
                values.append(StoredModelAlias(
                    provider: provider,
                    observedModelID: try requiredText(statement, at: 1),
                    canonicalModelID: try requiredText(statement, at: 2),
                    effectiveFrom: try requiredText(statement, at: 3),
                    effectiveTo: try optionalText(statement, at: 4)
                ))
            case SQLITE_DONE:
                return values
            default:
                throw failure(sqlite3_errcode(connection.handle), using: connection)
            }
        }
    }

    private func readExchangeRateSnapshots(
        using connection: SQLiteConnection
    ) throws -> [ExchangeRateSnapshot] {
        let statement = try prepare(
            """
            SELECT fx.catalog_id, fx.currency_code, fx.units_per_usd, fx.effective_date,
                   fx.provenance_url, fx.verified_at
            FROM fx_rates AS fx
            ORDER BY fx.catalog_id, fx.currency_code;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        var order: [String] = []
        var records: [String: StoredExchangeRateAccumulator] = [:]
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                let catalogID = try requiredText(statement, at: 0)
                guard let currency = DisplayCurrency(rawValue: try requiredText(statement, at: 1)) else {
                    throw LedgerError.corruptData("stored exchange-rate currency is invalid")
                }
                let rawRate = try requiredText(statement, at: 2)
                guard let rate = Decimal(
                    string: rawRate,
                    locale: Locale(identifier: "en_US_POSIX")
                ), !rate.isNaN, rate > 0, rate <= 100_000,
                DecimalString(decimal: rate).rawValue == rawRate else {
                    throw LedgerError.corruptData("stored exchange rate is invalid")
                }
                let effectiveDate = try requiredText(statement, at: 3)
                let rawProvenance = try requiredText(statement, at: 4)
                let verifiedAt = try requiredText(statement, at: 5)
                guard Self.isGregorianDay(effectiveDate), Self.isGregorianDay(verifiedAt),
                      let components = URLComponents(string: rawProvenance),
                      components.scheme?.lowercased() == "https",
                      components.host != nil,
                      let provenanceURL = components.url else {
                    throw LedgerError.corruptData("stored exchange-rate metadata is invalid")
                }
                if records[catalogID] == nil {
                    order.append(catalogID)
                    records[catalogID] = StoredExchangeRateAccumulator(
                        effectiveDate: effectiveDate,
                        verifiedAt: verifiedAt,
                        provenanceURL: provenanceURL,
                        rates: [:]
                    )
                }
                guard var record = records[catalogID],
                      record.effectiveDate == effectiveDate,
                      record.verifiedAt == verifiedAt,
                      record.provenanceURL == provenanceURL,
                      record.rates[currency] == nil else {
                    throw LedgerError.corruptData("stored exchange-rate snapshot is inconsistent")
                }
                record.rates[currency] = rate
                records[catalogID] = record
            case SQLITE_DONE:
                return try order.map { catalogID in
                    guard let record = records[catalogID],
                          Set(record.rates.keys) == Set(DisplayCurrency.allCases),
                          record.rates[.usd] == 1 else {
                        throw LedgerError.corruptData("stored exchange-rate snapshot is incomplete")
                    }
                    return ExchangeRateSnapshot(
                        catalogID: catalogID,
                        effectiveDate: record.effectiveDate,
                        verifiedAt: record.verifiedAt,
                        provenanceURL: record.provenanceURL,
                        rates: record.rates
                    )
                }
            default:
                throw failure(sqlite3_errcode(connection.handle), using: connection)
            }
        }
    }

    private func insertAliasIfNew(
        _ alias: CatalogAlias,
        model: ValidatedCatalogModel,
        catalogID: String,
        using connection: SQLiteConnection
    ) throws {
        let select = try prepare(
            """
            SELECT canonical_model_id, effective_to FROM model_aliases
            WHERE provider = ? AND observed_model_id = ? AND effective_from = ?;
            """,
            using: connection
        )
        defer { sqlite3_finalize(select) }
        try bind(model.provider.rawValue, to: select, at: 1, using: connection)
        try bind(alias.observedModelID, to: select, at: 2, using: connection)
        try bind(alias.effectiveFrom, to: select, at: 3, using: connection)
        switch sqlite3_step(select) {
        case SQLITE_ROW:
            let existingCanonical = try requiredText(select, at: 0)
            let existingEnd = try optionalText(select, at: 1)
            guard existingCanonical == model.canonicalModelID, existingEnd == alias.effectiveTo else {
                throw PricingLedgerError.semanticConflict(
                    "alias \(model.provider.rawValue)/\(alias.observedModelID)/\(alias.effectiveFrom)"
                )
            }
            return
        case SQLITE_DONE:
            break
        default:
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }

        let insert = try prepare(
            """
            INSERT INTO model_aliases(
              provider, observed_model_id, canonical_model_id, effective_from, effective_to, catalog_id
            ) VALUES(?, ?, ?, ?, ?, ?);
            """,
            using: connection
        )
        defer { sqlite3_finalize(insert) }
        try bind(model.provider.rawValue, to: insert, at: 1, using: connection)
        try bind(alias.observedModelID, to: insert, at: 2, using: connection)
        try bind(model.canonicalModelID, to: insert, at: 3, using: connection)
        try bind(alias.effectiveFrom, to: insert, at: 4, using: connection)
        try bind(alias.effectiveTo, to: insert, at: 5, using: connection)
        try bind(catalogID, to: insert, at: 6, using: connection)
        try stepDone(insert, using: connection)
    }

    private func insertRateIfNew(
        _ rate: ValidatedCatalogRate,
        metric: UsageMetric,
        price: Decimal,
        model: ValidatedCatalogModel,
        catalogID: String,
        using connection: SQLiteConnection
    ) throws {
        let canonicalPrice = DecimalString(decimal: price).rawValue
        let select = try prepare(
            """
            SELECT usd_per_million, effective_to, provenance_url, verified_at FROM price_rates
            WHERE provider = ? AND canonical_model_id = ? AND metric = ? AND effective_from = ?;
            """,
            using: connection
        )
        defer { sqlite3_finalize(select) }
        try bind(model.provider.rawValue, to: select, at: 1, using: connection)
        try bind(model.canonicalModelID, to: select, at: 2, using: connection)
        try bind(metric.rawValue, to: select, at: 3, using: connection)
        try bind(rate.effectiveFrom, to: select, at: 4, using: connection)
        switch sqlite3_step(select) {
        case SQLITE_ROW:
            let existingPrice = try requiredText(select, at: 0)
            let existingEnd = try optionalText(select, at: 1)
            let existingURL = try requiredText(select, at: 2)
            let existingVerifiedAt = try requiredText(select, at: 3)
            let identical = existingPrice == canonicalPrice
                && existingEnd == rate.effectiveTo
                && existingURL == rate.provenanceURL.absoluteString
                && existingVerifiedAt == rate.verifiedAt
            guard identical else {
                throw PricingLedgerError.semanticConflict(
                    "rate \(model.provider.rawValue)/\(model.canonicalModelID)/\(metric.rawValue)/\(rate.effectiveFrom)"
                )
            }
            return
        case SQLITE_DONE:
            break
        default:
            throw failure(sqlite3_errcode(connection.handle), using: connection)
        }

        let insert = try prepare(
            """
            INSERT INTO price_rates(
              provider, canonical_model_id, metric, usd_per_million, effective_from,
              effective_to, provenance_url, verified_at, catalog_id
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            using: connection
        )
        defer { sqlite3_finalize(insert) }
        try bind(model.provider.rawValue, to: insert, at: 1, using: connection)
        try bind(model.canonicalModelID, to: insert, at: 2, using: connection)
        try bind(metric.rawValue, to: insert, at: 3, using: connection)
        try bind(canonicalPrice, to: insert, at: 4, using: connection)
        try bind(rate.effectiveFrom, to: insert, at: 5, using: connection)
        try bind(rate.effectiveTo, to: insert, at: 6, using: connection)
        try bind(rate.provenanceURL.absoluteString, to: insert, at: 7, using: connection)
        try bind(rate.verifiedAt, to: insert, at: 8, using: connection)
        try bind(catalogID, to: insert, at: 9, using: connection)
        try stepDone(insert, using: connection)
    }

    private func insertExchangeRates(
        _ snapshot: ValidatedExchangeRateSnapshot,
        catalogID: String,
        using connection: SQLiteConnection
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO fx_rates(
              catalog_id, currency_code, units_per_usd, effective_date,
              provenance_url, verified_at
            ) VALUES(?, ?, ?, ?, ?, ?);
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        for currency in DisplayCurrency.allCases {
            guard let rate = snapshot.rates[currency] else {
                throw PricingLedgerError.semanticConflict(
                    "exchange rates \(catalogID)/\(currency.rawValue)"
                )
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            try bind(catalogID, to: statement, at: 1, using: connection)
            try bind(currency.rawValue, to: statement, at: 2, using: connection)
            try bind(DecimalString(decimal: rate).rawValue, to: statement, at: 3, using: connection)
            try bind(snapshot.effectiveDate, to: statement, at: 4, using: connection)
            try bind(snapshot.provenanceURL.absoluteString, to: statement, at: 5, using: connection)
            try bind(snapshot.verifiedAt, to: statement, at: 6, using: connection)
            try stepDone(statement, using: connection)
        }
    }

    private func insertCatalogImport(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: String,
        origin: String,
        validationSummary: String,
        using connection: SQLiteConnection
    ) throws -> Int64 {
        let statement = try prepare(
            """
            INSERT INTO catalog_imports(
              catalog_id, schema_version, origin, imported_at, validation_summary, canonical_json
            ) VALUES(?, ?, ?, ?, ?, ?);
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(catalog.catalogID, to: statement, at: 1, using: connection)
        try bind(Int64(catalog.schemaVersion), to: statement, at: 2, using: connection)
        try bind(origin, to: statement, at: 3, using: connection)
        try bind(importTimestamp(), to: statement, at: 4, using: connection)
        try bind(validationSummary, to: statement, at: 5, using: connection)
        try bind(canonicalJSON, to: statement, at: 6, using: connection)
        try stepDone(statement, using: connection)
        return sqlite3_last_insert_rowid(connection.handle)
    }

    private func selectActiveCatalogImport(
        _ importID: Int64,
        using connection: SQLiteConnection
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO active_catalog_import(singleton, import_id)
            VALUES(1, ?)
            ON CONFLICT(singleton) DO UPDATE SET import_id = excluded.import_id;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(importID, to: statement, at: 1, using: connection)
        try stepDone(statement, using: connection)
    }

    private func importTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func isGregorianDay(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard bytes.count == 10,
              bytes[4] == 0x2D,
              bytes[7] == 0x2D,
              bytes.enumerated().allSatisfy({ index, byte in
                  index == 4 || index == 7 || (0x30...0x39).contains(byte)
              }) else { return false }
        let year = bytes[0...3].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        let month = bytes[5...6].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        let day = bytes[8...9].reduce(0) { $0 * 10 + Int($1 - 0x30) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: year,
            month: month,
            day: day
        )) else { return false }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        return roundTrip.year == year && roundTrip.month == month && roundTrip.day == day
    }

    private func loadOrCreatePrivacyHasher(using connection: SQLiteConnection) throws -> PrivacyHasher {
        if let salt = try privacySalt(using: connection) {
            return PrivacyHasher(salt: salt)
        }

        var storedSalt: Data?
        try connection.beginTransaction()
        do {
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
            try connection.commitTransaction()
        } catch {
            try? connection.rollbackTransaction()
            throw error
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
        for entry in usage where !ModelIdentifierPolicy.isContentSafe(entry.observedModelID) {
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
            guard ModelIdentifierPolicy.isContentSafe(value) else {
                throw LedgerValidationError.invalidAdapterStateModelID
            }
        }
    }

    private func isOpaqueDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
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

    private func groupedHourly(
        _ usage: [NormalizedUsage],
        calendar: Calendar
    ) throws -> [HourlyUsageRow] {
        var quantities: [HourlyUsageKey: Int64] = [:]
        for entry in usage {
            guard let hourStart = calendar.dateInterval(of: .hour, for: entry.timestamp)?.start else {
                throw LedgerError.corruptData("could not calculate local usage hour")
            }
            let localDay = LocalDay(date: entry.timestamp, calendar: calendar)
            for (metric, quantity) in entry.metrics {
                let key = HourlyUsageKey(
                    hourStart: hourStart,
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
            HourlyUsageRow(
                hourStart: key.hourStart,
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

    private func upsertHourlyUsage(
        _ row: HourlyUsageRow,
        using connection: SQLiteConnection
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO hourly_usage(
              hour_start, local_day, time_zone, provider, observed_model_id,
              metric, aggregation, quantity
            ) VALUES(?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(hour_start, time_zone, provider, observed_model_id, metric)
            DO UPDATE SET quantity = quantity + excluded.quantity;
            """,
            using: connection
        )
        defer { sqlite3_finalize(statement) }
        try bind(epochSeconds(row.hourStart), to: statement, at: 1, using: connection)
        try bind(row.localDay.value, to: statement, at: 2, using: connection)
        try bind(row.localDay.timeZoneIdentifier, to: statement, at: 3, using: connection)
        try bind(row.provider.rawValue, to: statement, at: 4, using: connection)
        try bind(row.observedModelID, to: statement, at: 5, using: connection)
        try bind(row.metric.rawValue, to: statement, at: 6, using: connection)
        try bind(row.aggregation.rawValue, to: statement, at: 7, using: connection)
        try bind(row.quantity, to: statement, at: 8, using: connection)
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

    private func hourlyUsageRow(from statement: OpaquePointer) throws -> HourlyUsageRow {
        let localDay = try requiredText(statement, at: 1)
        let timeZone = try requiredText(statement, at: 2)
        guard let provider = Provider(rawValue: try requiredText(statement, at: 3)),
              let metric = UsageMetric(rawValue: try requiredText(statement, at: 5)),
              let aggregation = MetricAggregation(rawValue: try requiredText(statement, at: 6)) else {
            throw LedgerError.corruptData("hourly usage enum value is invalid")
        }
        return HourlyUsageRow(
            hourStart: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
            localDay: try decodedLocalDay(value: localDay, timeZoneIdentifier: timeZone),
            provider: provider,
            observedModelID: try requiredText(statement, at: 4),
            metric: metric,
            aggregation: aggregation,
            quantity: sqlite3_column_int64(statement, 7)
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

    private func epochSeconds(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
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

private struct StoredExchangeRateAccumulator {
    let effectiveDate: String
    let verifiedAt: String
    let provenanceURL: URL
    var rates: [DisplayCurrency: Decimal]
}

private struct UsageKey: Hashable {
    let localDay: LocalDay
    let provider: Provider
    let observedModelID: String
    let metric: UsageMetric
}

private struct HourlyUsageKey: Hashable {
    let hourStart: Date
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

}
