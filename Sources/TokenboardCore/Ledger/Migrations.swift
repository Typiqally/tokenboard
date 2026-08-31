public enum Migrations {
    public static let v1 = Migration(
        version: 1,
        name: "initial ledger schema",
        sql: """
        CREATE TABLE IF NOT EXISTS schema_migrations(
          version INTEGER PRIMARY KEY,
          name TEXT NOT NULL,
          checksum TEXT NOT NULL,
          applied_at TEXT NOT NULL
        );
        CREATE TABLE daily_usage(
          local_day TEXT NOT NULL,
          time_zone TEXT NOT NULL,
          provider TEXT NOT NULL,
          observed_model_id TEXT NOT NULL,
          metric TEXT NOT NULL,
          aggregation TEXT NOT NULL,
          quantity INTEGER NOT NULL CHECK(quantity >= 0),
          PRIMARY KEY(local_day, time_zone, provider, observed_model_id, metric)
        );
        CREATE INDEX daily_usage_day_idx ON daily_usage(local_day, provider);
        CREATE TABLE source_checkpoints(
          fingerprint TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          parser_version INTEGER NOT NULL,
          byte_offset INTEGER NOT NULL CHECK(byte_offset >= 0),
          file_size INTEGER NOT NULL CHECK(file_size >= 0),
          modification_time TEXT,
          last_usage_identity_hash TEXT,
          last_committed_line_hash TEXT,
          cumulative_metrics_json TEXT NOT NULL,
          adapter_state_json TEXT NOT NULL
        );
        CREATE TABLE skipped_records(
          source_fingerprint TEXT NOT NULL,
          byte_offset INTEGER NOT NULL,
          record_hash TEXT NOT NULL,
          parser_version INTEGER NOT NULL,
          reason TEXT NOT NULL,
          PRIMARY KEY(source_fingerprint, byte_offset, record_hash)
        );
        CREATE TABLE price_rates(
          provider TEXT NOT NULL,
          canonical_model_id TEXT NOT NULL,
          metric TEXT NOT NULL,
          usd_per_million TEXT NOT NULL,
          effective_from TEXT NOT NULL,
          effective_to TEXT,
          provenance_url TEXT NOT NULL,
          verified_at TEXT NOT NULL,
          catalog_id TEXT NOT NULL,
          PRIMARY KEY(provider, canonical_model_id, metric, effective_from)
        );
        CREATE INDEX price_rate_lookup_idx ON price_rates(provider, canonical_model_id, metric, effective_from, effective_to);
        CREATE TABLE model_aliases(
          provider TEXT NOT NULL,
          observed_model_id TEXT NOT NULL,
          canonical_model_id TEXT NOT NULL,
          effective_from TEXT NOT NULL,
          effective_to TEXT,
          catalog_id TEXT NOT NULL,
          PRIMARY KEY(provider, observed_model_id, effective_from)
        );
        CREATE INDEX model_alias_lookup_idx ON model_aliases(provider, observed_model_id, effective_from, effective_to);
        CREATE TABLE catalog_imports(
          catalog_id TEXT PRIMARY KEY,
          schema_version INTEGER NOT NULL,
          origin TEXT NOT NULL,
          imported_at TEXT NOT NULL,
          applied INTEGER NOT NULL CHECK(applied IN (0, 1)),
          validation_summary TEXT NOT NULL,
          canonical_json TEXT NOT NULL
        );
        CREATE TABLE app_metadata(
          key TEXT PRIMARY KEY,
          value BLOB NOT NULL
        );
        """
    )

    public static let v2 = Migration(
        version: 2,
        name: "enforce integer daily usage quantities",
        sql: """
        CREATE TRIGGER daily_usage_quantity_integer_insert
        BEFORE INSERT ON daily_usage
        FOR EACH ROW WHEN typeof(NEW.quantity) <> 'integer'
        BEGIN
          SELECT RAISE(ABORT, 'daily_usage.quantity must be INTEGER');
        END;
        CREATE TRIGGER daily_usage_quantity_integer_update
        BEFORE UPDATE OF quantity ON daily_usage
        FOR EACH ROW WHEN typeof(NEW.quantity) <> 'integer'
        BEGIN
          SELECT RAISE(ABORT, 'daily_usage.quantity must be INTEGER');
        END;
        """
    )

    public static let v3 = Migration(
        version: 3,
        name: "store approved exchange rate snapshots",
        sql: """
        CREATE TABLE fx_rates(
          catalog_id TEXT NOT NULL,
          currency_code TEXT NOT NULL,
          units_per_usd TEXT NOT NULL,
          effective_date TEXT NOT NULL,
          provenance_url TEXT NOT NULL,
          verified_at TEXT NOT NULL,
          PRIMARY KEY(catalog_id, currency_code)
        );
        CREATE INDEX fx_rate_catalog_idx ON fx_rates(catalog_id, currency_code);
        """
    )

    public static let v4 = Migration(
        version: 4,
        name: "store hourly usage progression",
        sql: """
        CREATE TABLE hourly_usage(
          hour_start INTEGER NOT NULL,
          local_day TEXT NOT NULL,
          time_zone TEXT NOT NULL,
          provider TEXT NOT NULL,
          observed_model_id TEXT NOT NULL,
          metric TEXT NOT NULL,
          aggregation TEXT NOT NULL,
          quantity INTEGER NOT NULL CHECK(quantity >= 0),
          PRIMARY KEY(hour_start, time_zone, provider, observed_model_id, metric)
        );
        CREATE INDEX hourly_usage_range_idx ON hourly_usage(hour_start, provider);
        CREATE TRIGGER hourly_usage_quantity_integer_insert
        BEFORE INSERT ON hourly_usage
        FOR EACH ROW WHEN typeof(NEW.quantity) <> 'integer'
        BEGIN
          SELECT RAISE(ABORT, 'hourly_usage.quantity must be INTEGER');
        END;
        CREATE TRIGGER hourly_usage_quantity_integer_update
        BEFORE UPDATE OF quantity ON hourly_usage
        FOR EACH ROW WHEN typeof(NEW.quantity) <> 'integer'
        BEGIN
          SELECT RAISE(ABORT, 'hourly_usage.quantity must be INTEGER');
        END;
        """
    )

    public static let v5 = Migration(
        version: 5,
        name: "preserve immutable pricing import history",
        sql: """
        ALTER TABLE catalog_imports RENAME TO catalog_imports_legacy;
        CREATE TABLE catalog_imports(
          import_id INTEGER PRIMARY KEY AUTOINCREMENT,
          catalog_id TEXT NOT NULL,
          schema_version INTEGER NOT NULL,
          origin TEXT NOT NULL,
          imported_at TEXT NOT NULL,
          validation_summary TEXT NOT NULL,
          canonical_json TEXT NOT NULL
        );
        CREATE INDEX catalog_imports_catalog_idx
          ON catalog_imports(catalog_id, import_id);
        INSERT INTO catalog_imports(
          catalog_id, schema_version, origin, imported_at,
          validation_summary, canonical_json
        )
        SELECT catalog_id, schema_version, origin, imported_at,
               validation_summary, canonical_json
        FROM catalog_imports_legacy
        ORDER BY imported_at, rowid;
        CREATE TABLE active_catalog_import(
          singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
          import_id INTEGER NOT NULL UNIQUE
            REFERENCES catalog_imports(import_id) ON DELETE RESTRICT
        );
        INSERT INTO active_catalog_import(singleton, import_id)
        SELECT 1, imports.import_id
        FROM catalog_imports AS imports
        WHERE imports.catalog_id = (
          SELECT catalog_id
          FROM catalog_imports_legacy
          WHERE applied = 1
          ORDER BY imported_at DESC, rowid DESC
          LIMIT 1
        )
        ORDER BY imports.import_id DESC
        LIMIT 1;
        DROP TABLE catalog_imports_legacy;
        CREATE TRIGGER catalog_imports_immutable_update
        BEFORE UPDATE ON catalog_imports
        BEGIN
          SELECT RAISE(ABORT, 'catalog import history is immutable');
        END;
        CREATE TRIGGER catalog_imports_immutable_delete
        BEFORE DELETE ON catalog_imports
        BEGIN
          SELECT RAISE(ABORT, 'catalog import history is immutable');
        END;
        """
    )

    public static let v6 = Migration(
        version: 6,
        name: "store privacy-limited activity slices",
        sql: """
        CREATE TABLE activity_slices(
          slice_start INTEGER NOT NULL,
          local_day TEXT NOT NULL,
          time_zone TEXT NOT NULL,
          provider TEXT NOT NULL,
          PRIMARY KEY(slice_start, time_zone, provider)
        );
        CREATE INDEX activity_slices_range_idx
          ON activity_slices(slice_start, provider);
        """
    )

    public static let all = [v1, v2, v3, v4, v5, v6]
}
