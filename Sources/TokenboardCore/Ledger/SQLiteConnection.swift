import CSQLite
import CryptoKit
import Darwin
import Foundation

public struct SQLiteFailure: Error, CustomStringConvertible {
    public let code: Int32
    public let message: String

    public var description: String { "SQLite \(code): \(message)" }
}

public enum SQLiteValue: Sendable, Equatable {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

public final class SQLiteConnection {
    let handle: OpaquePointer
    private var isClosed = false

    public convenience init(url: URL) throws {
        try self.init(
            filename: url.path,
            flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            configureForLedger: true
        )
    }

    private init(
        filename: String,
        flags: Int32,
        configureForLedger: Bool
    ) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(
            filename,
            &pointer,
            flags,
            nil
        )
        guard result == SQLITE_OK, let pointer else {
            let message = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            if let pointer {
                sqlite3_close(pointer)
            }
            throw SQLiteFailure(code: result, message: message)
        }

        handle = pointer
        if configureForLedger {
            try execute("PRAGMA foreign_keys = ON;")
            try execute("PRAGMA journal_mode = WAL;")
        }
    }

    static func recoveryConnection(
        descriptor: Int32,
        byteCount: Int,
        maximumBytes: Int
    ) throws -> SQLiteConnection {
        try capturedRecoveryConnection(
            descriptor: descriptor,
            byteCount: byteCount,
            maximumBytes: maximumBytes
        ).connection
    }

    static func capturedRecoveryConnection(
        descriptor: Int32,
        byteCount: Int,
        maximumBytes: Int
    ) throws -> (connection: SQLiteConnection, digest: String) {
        guard byteCount >= 20, byteCount <= maximumBytes else {
            throw SQLiteFailure(code: SQLITE_NOTADB, message: "database image is too small")
        }
        let connection = try SQLiteConnection(
            filename: ":memory:",
            flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            configureForLedger: false
        )
        let (doubled, overflowed) = byteCount.multipliedReportingOverflow(by: 2)
        let capacity = min(maximumBytes, overflowed ? maximumBytes : doubled)
        guard capacity >= byteCount else {
            try? connection.close()
            throw SQLiteFailure(code: SQLITE_TOOBIG, message: "recovery image exceeds capacity")
        }
        guard let allocation = sqlite3_malloc64(sqlite3_uint64(capacity)) else {
            try? connection.close()
            throw SQLiteFailure(code: SQLITE_NOMEM, message: "unable to allocate recovery image")
        }
        let bytes = allocation.assumingMemoryBound(to: UInt8.self)
        var readCount = 0
        var hasher = SHA256()
        while readCount < byteCount {
            let result = pread(descriptor, bytes.advanced(by: readCount), byteCount - readCount, off_t(readCount))
            guard result > 0 else {
                if result < 0, errno == EINTR { continue }
                sqlite3_free(allocation)
                try? connection.close()
                throw SQLiteFailure(code: SQLITE_IOERR, message: "unable to read recovery image")
            }
            hasher.update(data: Data(bytes: bytes.advanced(by: readCount), count: result))
            readCount += result
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        // sqlite3_deserialize cannot accept a WAL-mode image. A completed checkpoint
        // makes the main file self-contained, so select rollback-journal mode in the
        // private image before SQLite sees it.
        bytes[18] = 1
        bytes[19] = 1
        let result = sqlite3_deserialize(
            connection.handle,
            "main",
            bytes,
            sqlite3_int64(byteCount),
            sqlite3_int64(capacity),
            UInt32(SQLITE_DESERIALIZE_FREEONCLOSE)
        )
        guard result == SQLITE_OK else {
            // FREEONCLOSE transfers ownership even when sqlite3_deserialize fails.
            try? connection.close()
            throw SQLiteFailure(code: result, message: "unable to deserialize recovery image")
        }
        do {
            try connection.execute("PRAGMA foreign_keys = ON;")
            return (connection, digest)
        } catch {
            try? connection.close()
            throw error
        }
    }

    static func transient() throws -> SQLiteConnection {
        try SQLiteConnection(
            filename: ":memory:",
            flags: SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            configureForLedger: false
        )
    }

    static func immutableDescriptor(_ descriptor: Int32) throws -> SQLiteConnection {
        try SQLiteConnection(
            filename: "file:/dev/fd/\(descriptor)?immutable=1",
            flags: SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_FULLMUTEX,
            configureForLedger: false
        )
    }

    func writeSerializedDatabase(to descriptor: Int32, maximumBytes: Int) throws {
        var size: sqlite3_int64 = 0
        guard let bytes = sqlite3_serialize(
            handle,
            "main",
            &size,
            UInt32(SQLITE_SERIALIZE_NOCOPY)
        ), size >= 0,
           size <= sqlite3_int64(maximumBytes),
           let count = Int(exactly: size) else {
            throw SQLiteFailure(
                code: size > sqlite3_int64(maximumBytes) ? SQLITE_TOOBIG : sqlite3_errcode(handle),
                message: size > sqlite3_int64(maximumBytes)
                    ? "serialized recovery image exceeds the configured limit"
                    : "unable to access the serialized recovery image"
            )
        }
        guard ftruncate(descriptor, 0) == 0 else {
            throw SQLiteFailure(code: SQLITE_IOERR, message: "unable to truncate staged recovery image")
        }
        var written = 0
        while written < count {
            let result = pwrite(descriptor, bytes.advanced(by: written), count - written, off_t(written))
            guard result > 0 else {
                if result < 0, errno == EINTR { continue }
                throw SQLiteFailure(code: SQLITE_IOERR, message: "unable to write staged recovery image")
            }
            written += result
        }
    }

    deinit {
        if !isClosed {
            sqlite3_close_v2(handle)
        }
    }

    public func close() throws {
        guard !isClosed else { return }
        let result = sqlite3_close(handle)
        guard result == SQLITE_OK else {
            throw SQLiteFailure(
                code: result,
                message: String(cString: sqlite3_errmsg(handle))
            )
        }
        isClosed = true
    }

    public func checkpointWAL() throws {
        var logFrames: Int32 = -1
        var checkpointedFrames: Int32 = -1
        let result = sqlite3_wal_checkpoint_v2(
            handle,
            "main",
            SQLITE_CHECKPOINT_TRUNCATE,
            &logFrames,
            &checkpointedFrames
        )
        guard Self.isCompleteTruncateCheckpoint(
            result: result,
            logFrames: logFrames,
            checkpointedFrames: checkpointedFrames
        ) else {
            throw SQLiteFailure(
                code: result == SQLITE_OK ? SQLITE_BUSY : result,
                message: result == SQLITE_OK
                    ? "WAL checkpoint did not fully truncate"
                    : String(cString: sqlite3_errmsg(handle))
            )
        }
    }

    static func isCompleteTruncateCheckpoint(
        result: Int32,
        logFrames: Int32,
        checkpointedFrames: Int32
    ) -> Bool {
        result == SQLITE_OK
            && ((logFrames == -1 && checkpointedFrames == -1)
                || (logFrames == 0 && checkpointedFrames == 0))
    }

    public func execute(_ sql: String) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorPointer)
        guard result == SQLITE_OK else {
            let message = errorPointer.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorPointer)
            throw SQLiteFailure(code: result, message: message)
        }
    }

    public func transaction(
        isolation: isolated (any Actor)? = #isolation,
        _ body: () throws -> Void
    ) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func queryStrings(_ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteFailure(code: prepareResult, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                values.append(try sqliteText(statement, at: 0, using: self))
            case SQLITE_DONE:
                return values
            default:
                throw SQLiteFailure(code: result, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    public var userVersion: Int32 {
        get throws {
            let rows = try queryStrings("PRAGMA user_version;")
            guard rows.count == 1, let version = Int32(rows[0]) else {
                throw SQLiteFailure(code: SQLITE_CORRUPT, message: "invalid user_version")
            }
            return version
        }
    }

    public func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    func textBindingRoundTripForTesting(_ value: String) throws -> String {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(handle, "SELECT ?;", -1, &statement, nil)
        guard prepareResult == SQLITE_OK, let statement else {
            throw SQLiteFailure(code: prepareResult, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        try sqliteBindText(value, to: statement, at: 1, using: self)
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_ROW else {
            throw SQLiteFailure(code: stepResult, message: String(cString: sqlite3_errmsg(handle)))
        }
        return try sqliteText(statement, at: 0, using: self)
    }
}

func sqliteBindText(_ value: String, to statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws {
    let data = Data(value.utf8)
    guard data.count <= Int(Int32.max) else {
        throw SQLiteFailure(code: SQLITE_TOOBIG, message: "SQLite text binding exceeds maximum length")
    }
    let result = data.withUnsafeBytes { bytes in
        sqlite3_bind_text(
            statement,
            index,
            bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
            Int32(data.count),
            sqliteTransient
        )
    }
    guard result == SQLITE_OK else {
        throw SQLiteFailure(code: result, message: String(cString: sqlite3_errmsg(connection.handle)))
    }
}

func sqliteText(_ statement: OpaquePointer, at index: Int32, using connection: SQLiteConnection) throws -> String {
    guard let pointer = sqlite3_column_text(statement, index) else {
        throw SQLiteFailure(code: SQLITE_CORRUPT, message: "required SQLite text value is NULL")
    }
    let length = Int(sqlite3_column_bytes(statement, index))
    guard let value = String(bytes: UnsafeBufferPointer(start: pointer, count: length), encoding: .utf8) else {
        throw SQLiteFailure(code: SQLITE_CORRUPT, message: "SQLite text value is not valid UTF-8")
    }
    return value
}

let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
