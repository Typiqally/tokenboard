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
        guard prepareResult == SQLITE_OK else {
            throw SQLiteFailure(code: prepareResult, message: String(cString: sqlite3_errmsg(handle)))
        }
        defer {
            sqlite3_finalize(statement)
        }

        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    values.append(String(cString: text))
                }
            case SQLITE_DONE:
                return values
            default:
                throw SQLiteFailure(code: result, message: String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    public var userVersion: Int32 {
        (try? queryStrings("PRAGMA user_version;").first.flatMap(Int32.init)) ?? 0
    }

    public func setUserVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }
}
