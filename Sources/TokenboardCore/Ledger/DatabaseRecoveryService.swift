import Foundation

public struct DatabaseBackup: Equatable, Sendable {
    public let url: URL
    public let modificationDate: Date

    public init(url: URL, modificationDate: Date) {
        self.url = url
        self.modificationDate = modificationDate
    }
}

public enum DatabaseRecoveryError: Error, Equatable, Sendable {
    case invalidDatabaseLocation
    case noBackupAvailable
    case databaseMissing
    case restoreFailed
    case rollbackFailed
}

public actor DatabaseRecoveryService {
    private static let databaseFilename = "ledger.sqlite"
    private static let backupPattern = try! NSRegularExpression(
        pattern: #"^ledger-v[0-9]+-[0-9]+\.sqlite$"#
    )

    private let databaseURL: URL
    private let backupDirectory: URL
    private let fileManager: FileManager

    public init(
        databaseURL: URL,
        backupDirectory: URL,
        fileManager: FileManager = .default
    ) {
        self.databaseURL = databaseURL.standardizedFileURL
        self.backupDirectory = backupDirectory.standardizedFileURL
        self.fileManager = fileManager
    }

    public func availableBackups() throws -> [DatabaseBackup] {
        guard fileManager.fileExists(atPath: backupDirectory.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: backupDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url -> DatabaseBackup? in
            let filename = url.lastPathComponent
            let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
            guard Self.backupPattern.firstMatch(in: filename, range: range)?.range == range else {
                return nil
            }
            let values = try url.resourceValues(forKeys: [
                .contentModificationDateKey,
                .isRegularFileKey
            ])
            guard values.isRegularFile == true else { return nil }
            return DatabaseBackup(
                url: url.standardizedFileURL,
                modificationDate: values.contentModificationDate ?? .distantPast
            )
        }.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            return lhs.url.lastPathComponent > rhs.url.lastPathComponent
        }
    }

    @discardableResult
    public func restoreLatest(
        afterShutdown: @Sendable () async throws -> Void
    ) async throws -> DatabaseBackup {
        guard databaseURL.lastPathComponent == Self.databaseFilename else {
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
        guard let backup = try availableBackups().first else {
            throw DatabaseRecoveryError.noBackupAvailable
        }
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw DatabaseRecoveryError.databaseMissing
        }

        try await afterShutdown()

        let identifier = UUID().uuidString
        let parent = databaseURL.deletingLastPathComponent()
        let temporary = parent.appending(path: ".tokenboard-restore-\(identifier).sqlite")
        let rollbackName = ".tokenboard-pre-restore-\(identifier).sqlite"
        let rollback = parent.appending(path: rollbackName)
        var replacementBegan = false

        do {
            try fileManager.copyItem(at: backup.url, to: temporary)
            try fileManager.copyItem(at: databaseURL, to: rollback)
            replacementBegan = true
            _ = try fileManager.replaceItemAt(
                databaseURL,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
            try removeExactSidecars()
            try await validateRestoredDatabase(identifier: identifier)
            try removeExactSidecars()
            try fileManager.removeItem(at: rollback)
            return backup
        } catch {
            try? removeIfPresent(temporary)
            guard replacementBegan else {
                try? removeIfPresent(rollback)
                throw DatabaseRecoveryError.restoreFailed
            }
            do {
                guard fileManager.fileExists(atPath: rollback.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                _ = try fileManager.replaceItemAt(
                    databaseURL,
                    withItemAt: rollback,
                    backupItemName: nil,
                    options: []
                )
                try removeExactSidecars()
            } catch {
                throw DatabaseRecoveryError.rollbackFailed
            }
            throw DatabaseRecoveryError.restoreFailed
        }
    }

    private func validateRestoredDatabase(identifier: String) async throws {
        let validationBackups = databaseURL.deletingLastPathComponent().appending(
            path: ".tokenboard-validation-backups-\(identifier)",
            directoryHint: .isDirectory
        )
        defer { try? removeIfPresent(validationBackups) }
        let ledger = try SQLiteLedger(
            databaseURL: databaseURL,
            backupDirectory: validationBackups
        )
        do {
            try await ledger.migrate()
            try await ledger.integrityCheck()
            try await ledger.shutdown()
        } catch {
            try? await ledger.shutdown()
            throw error
        }
    }

    private func removeExactSidecars() throws {
        let parent = databaseURL.deletingLastPathComponent()
        try removeIfPresent(parent.appending(path: "ledger.sqlite-wal"))
        try removeIfPresent(parent.appending(path: "ledger.sqlite-shm"))
    }

    private func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }
}
