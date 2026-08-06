import CSQLite
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

    public init(url: URL) throws {
        var pointer: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
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
        try execute("PRAGMA foreign_keys = ON;")
        try execute("PRAGMA journal_mode = WAL;")
    }

    deinit {
        sqlite3_close(handle)
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

    public func transaction(_ body: () throws -> Void) throws {
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
