import CryptoKit
import Darwin
import Foundation

public struct DatabaseBackup: Equatable, Identifiable, Sendable {
    public let id: String
    public let modificationDate: Date

    let filename: String
    fileprivate let identity: RecoveryFileIdentity

    fileprivate init(filename: String, identity: RecoveryFileIdentity) {
        self.filename = filename
        self.identity = identity
        id = identity.token(filename: filename)
        modificationDate = identity.modificationDate
    }
}

public enum DatabaseRecoveryError: Error, Equatable, Sendable {
    case invalidDatabaseLocation
    case noBackupAvailable
    case databaseMissing
    case restoreInProgress
    case backupChanged
    case unsafeBackup
    case unsafeDatabase
    case unsafeSidecar
    case restoreFailed
    case rollbackFailed
    case cleanupPending
    case restoreFailedCleanupPending
    case rollbackCompleted
    case preservationRetryRequired
    case preservationFailed
    case backupTooLarge(maximumBytes: Int)
}

enum DatabaseRecoveryStage: Equatable, Sendable {
    case beforeReplacement
    case afterReplacement
    case afterValidation
    case beforeRollback
    case afterRollback
}

enum DatabaseRecoveryFileOperation: Equatable, Sendable {
    case restoreCopyChunk
    case rollbackCopyChunk
    case syncStagedRestore
    case syncRollbackSnapshot
    case removeSidecar
    case syncBeforeReplacement
    case syncAfterReplacement
    case syncCleanup
    case syncRollbackInstall
    case syncBeforeRollback
    case syncAfterRollback
    case retainSnapshotDescriptor
    case retainParentDescriptor
    case syncPreservationArtifact
    case syncSnapshotPruning
}

public actor DatabaseRecoveryService {
    /// Recovery is intentionally capped so a selected file cannot force an
    /// unbounded allocation while it is migrated in a private SQLite image.
    public static let maximumRecoveryImageBytes = 256 * 1_024 * 1_024
    private static let databaseFilename = "ledger.sqlite"
    private static let backupDirectoryName = "Backups"
    private static let backupPattern = try! NSRegularExpression(
        pattern: #"^ledger-v[0-9]+-[0-9]+\.sqlite$"#
    )
    private static let sidecarNames = ["ledger.sqlite-wal", "ledger.sqlite-shm"]

    private let databaseURL: URL
    private let backupDirectory: URL
    private let hasValidLexicalNamespace: Bool
    private let stageHandler: @Sendable (DatabaseRecoveryStage) async throws -> Void
    private let fileOperationHandler: @Sendable (DatabaseRecoveryFileOperation) throws -> Void
    private let maximumRecoveryImageBytes: Int
    private var restoreInProgress = false
    private var pendingPreservation: PendingRecoveryPreservation?

    public init(databaseURL: URL, backupDirectory: URL) {
        let standardizedDatabase = databaseURL.standardizedFileURL
        let standardizedBackups = backupDirectory.standardizedFileURL
        let canonicalDatabase = Self.canonicalSystemURL(standardizedDatabase)
        let canonicalBackups = Self.canonicalSystemURL(standardizedBackups)
        self.databaseURL = canonicalDatabase
        self.backupDirectory = canonicalBackups
        hasValidLexicalNamespace = databaseURL.isFileURL
            && backupDirectory.isFileURL
            && databaseURL.path == standardizedDatabase.path
            && backupDirectory.path == standardizedBackups.path
            && standardizedDatabase.lastPathComponent == Self.databaseFilename
            && standardizedBackups.lastPathComponent == Self.backupDirectoryName
            && standardizedBackups.deletingLastPathComponent() == standardizedDatabase
                .deletingLastPathComponent()
            && canonicalBackups.deletingLastPathComponent() == canonicalDatabase
                .deletingLastPathComponent()
        stageHandler = { _ in }
        fileOperationHandler = { _ in }
        maximumRecoveryImageBytes = Self.maximumRecoveryImageBytes
    }

    init(
        databaseURL: URL,
        backupDirectory: URL,
        stageHandler: @escaping @Sendable (DatabaseRecoveryStage) async throws -> Void,
        fileOperationHandler: @escaping @Sendable (DatabaseRecoveryFileOperation) throws -> Void = { _ in },
        maximumRecoveryImageBytes: Int = DatabaseRecoveryService.maximumRecoveryImageBytes
    ) {
        let standardizedDatabase = databaseURL.standardizedFileURL
        let standardizedBackups = backupDirectory.standardizedFileURL
        let canonicalDatabase = Self.canonicalSystemURL(standardizedDatabase)
        let canonicalBackups = Self.canonicalSystemURL(standardizedBackups)
        self.databaseURL = canonicalDatabase
        self.backupDirectory = canonicalBackups
        hasValidLexicalNamespace = databaseURL.isFileURL
            && backupDirectory.isFileURL
            && databaseURL.path == standardizedDatabase.path
            && backupDirectory.path == standardizedBackups.path
            && standardizedDatabase.lastPathComponent == Self.databaseFilename
            && standardizedBackups.lastPathComponent == Self.backupDirectoryName
            && standardizedBackups.deletingLastPathComponent() == standardizedDatabase
                .deletingLastPathComponent()
            && canonicalBackups.deletingLastPathComponent() == canonicalDatabase
                .deletingLastPathComponent()
        self.stageHandler = stageHandler
        self.fileOperationHandler = fileOperationHandler
        self.maximumRecoveryImageBytes = maximumRecoveryImageBytes
    }

    deinit {
        pendingPreservation?.close()
    }

    public func availableBackups() throws -> [DatabaseBackup] {
        let descriptors = try openDirectories(allowMissingBackups: true)
        defer { descriptors.close() }
        guard descriptors.backups >= 0 else { return [] }

        var backups: [DatabaseBackup] = []
        var foundOversized = false
        for filename in try listNames(in: descriptors.backups) {
            guard Self.isBackupFilename(filename) else { continue }
            let descriptor: Int32
            do {
                descriptor = try openRegular(
                    in: descriptors.backups,
                    name: filename,
                    missing: .unsafeBackup,
                    unsafe: .unsafeBackup
                )
            } catch DatabaseRecoveryError.unsafeBackup {
                continue
            }
            defer { Darwin.close(descriptor) }
            do {
                _ = try boundedByteCount(of: descriptor, unsafe: .unsafeBackup)
            } catch DatabaseRecoveryError.backupTooLarge {
                foundOversized = true
                continue
            } catch {
                continue
            }
            backups.append(DatabaseBackup(
                filename: filename,
                identity: try identity(of: descriptor)
            ))
        }
        if backups.isEmpty, foundOversized {
            throw DatabaseRecoveryError.backupTooLarge(
                maximumBytes: maximumRecoveryImageBytes
            )
        }
        return backups.sorted { lhs, rhs in
            if lhs.modificationDate != rhs.modificationDate {
                return lhs.modificationDate > rhs.modificationDate
            }
            return lhs.filename > rhs.filename
        }
    }

    @discardableResult
    public func restore(
        _ confirmedBackup: DatabaseBackup,
        afterShutdown: @Sendable () async throws -> Void
    ) async throws -> DatabaseBackup {
        guard pendingPreservation == nil else {
            throw DatabaseRecoveryError.preservationRetryRequired
        }
        guard !restoreInProgress else { throw DatabaseRecoveryError.restoreInProgress }
        restoreInProgress = true
        defer { restoreInProgress = false }

        try Task.checkCancellation()
        try await afterShutdown()
        try Task.checkCancellation()

        let descriptors = try openDirectories(allowMissingBackups: false)
        defer { descriptors.close() }
        let backupDescriptor = try openConfirmedBackup(confirmedBackup, in: descriptors.backups)
        defer { Darwin.close(backupDescriptor) }
        let databaseDescriptor = try openRegular(
            in: descriptors.parent,
            name: Self.databaseFilename,
            missing: .databaseMissing,
            unsafe: .unsafeDatabase
        )
        defer { Darwin.close(databaseDescriptor) }
        try validateSidecars(in: descriptors.parent)

        let identifier = UUID().uuidString
        let restoreName = ".tokenboard-restore-\(identifier).sqlite"
        let rollbackName = ".tokenboard-pre-restore-\(identifier).sqlite"
        let rollbackInstallName = ".tokenboard-rollback-install-\(identifier).sqlite"
        var replacementBegan = false
        var restoreDescriptor: Int32 = -1
        var rollbackDescriptor: Int32 = -1
        var retainedRollbackIdentity: RecoveryFileIdentity?
        defer {
            if restoreDescriptor >= 0 { Darwin.close(restoreDescriptor) }
            if rollbackDescriptor >= 0 { Darwin.close(rollbackDescriptor) }
        }

        do {
            restoreDescriptor = try createRegular(in: descriptors.parent, name: restoreName)
            let copiedDigest = try copy(
                from: backupDescriptor,
                to: restoreDescriptor,
                operation: .restoreCopyChunk,
                syncOperation: .syncStagedRestore
            )
            guard copiedDigest == confirmedBackup.identity.digest,
                  try identity(of: backupDescriptor) == confirmedBackup.identity else {
                throw DatabaseRecoveryError.backupChanged
            }
            try await prepareStagedDatabase(restoreDescriptor)
            let stagedIdentity = try identity(of: restoreDescriptor)

            let databaseIdentity = try identity(of: databaseDescriptor)
            rollbackDescriptor = try createRegular(in: descriptors.parent, name: rollbackName)
            let rollbackDigest = try copy(
                from: databaseDescriptor,
                to: rollbackDescriptor,
                syncOperation: .syncRollbackSnapshot
            )
            guard rollbackDigest == databaseIdentity.digest,
                  try identity(of: databaseDescriptor) == databaseIdentity else {
                throw DatabaseRecoveryError.unsafeDatabase
            }
            guard fchmod(rollbackDescriptor, S_IRUSR) == 0,
                  fsync(rollbackDescriptor) == 0 else { throw posixFailure() }
            let rollbackIdentity = try identity(of: rollbackDescriptor)
            retainedRollbackIdentity = rollbackIdentity

            try await stageHandler(.beforeReplacement)
            try Task.checkCancellation()
            try ensureParentDirectoryBinding(descriptors.parent)
            try ensureNameBindsToDescriptor(
                restoreDescriptor,
                expected: stagedIdentity,
                in: descriptors.parent,
                name: restoreName,
                unsafe: .restoreFailed
            )
            try ensureNameBindsToDescriptor(
                databaseDescriptor,
                expected: databaseIdentity,
                in: descriptors.parent,
                name: Self.databaseFilename,
                unsafe: .unsafeDatabase
            )
            try ensureNameBindsToDescriptor(
                rollbackDescriptor,
                expected: rollbackIdentity,
                in: descriptors.parent,
                name: rollbackName,
                unsafe: .restoreFailed
            )
            try removeExactSidecars(
                in: descriptors.parent,
                syncOperation: .syncBeforeReplacement
            )
            guard renameat(
                descriptors.parent,
                restoreName,
                descriptors.parent,
                Self.databaseFilename
            ) == 0 else { throw posixFailure() }
            replacementBegan = true
            try syncDirectory(descriptors.parent, operation: .syncAfterReplacement)
            try await stageHandler(.afterReplacement)
            try Task.checkCancellation()
            try ensureParentDirectoryBinding(descriptors.parent)
            try ensureNameBindsToDescriptor(
                restoreDescriptor,
                expected: stagedIdentity,
                in: descriptors.parent,
                name: Self.databaseFilename,
                unsafe: .restoreFailed
            )
            try validateDatabase(on: restoreDescriptor, expected: stagedIdentity)
            try await stageHandler(.afterValidation)
            try Task.checkCancellation()
            try ensureParentDirectoryBinding(descriptors.parent)
            try ensureNameBindsToDescriptor(
                restoreDescriptor,
                expected: stagedIdentity,
                in: descriptors.parent,
                name: Self.databaseFilename,
                unsafe: .restoreFailed
            )
            do {
                try syncDirectory(descriptors.parent, operation: .syncCleanup)
                try verifyFinalIdentity(
                    restoreDescriptor,
                    expected: stagedIdentity,
                    in: descriptors.parent,
                    name: Self.databaseFilename,
                    unsafe: .restoreFailed
                )
                try verifyRecoveryArtifact(
                    rollbackDescriptor,
                    expected: rollbackIdentity,
                    in: descriptors.parent,
                    name: rollbackName
                )
                try pruneRecoverySnapshots(
                    in: descriptors.parent,
                    preserving: rollbackName
                )
            } catch let recovery as DatabaseRecoveryError
                where recovery == .restoreFailed || recovery == .preservationFailed {
                throw recovery
            } catch {
                do {
                    try verifyFinalIdentity(
                        restoreDescriptor,
                        expected: stagedIdentity,
                        in: descriptors.parent,
                        name: Self.databaseFilename,
                        unsafe: .restoreFailed
                    )
                } catch {
                    throw DatabaseRecoveryError.restoreFailed
                }
                do {
                    try verifyRecoveryArtifact(
                        rollbackDescriptor,
                        expected: rollbackIdentity,
                        in: descriptors.parent,
                        name: rollbackName
                    )
                } catch {
                    throw DatabaseRecoveryError.preservationFailed
                }
                throw DatabaseRecoveryError.cleanupPending
            }
            return confirmedBackup
        } catch {
            if let recovery = error as? DatabaseRecoveryError,
               recovery == .cleanupPending || recovery == .preservationFailed {
                if recovery == .preservationFailed, let retainedRollbackIdentity {
                    do {
                        try retainPendingPreservation(
                            snapshot: rollbackDescriptor,
                            identity: retainedRollbackIdentity,
                            parent: descriptors.parent
                        )
                    } catch {
                        throw DatabaseRecoveryError.preservationFailed
                    }
                    throw DatabaseRecoveryError.preservationRetryRequired
                }
                throw recovery
            }
            guard replacementBegan else {
                do {
                    if restoreDescriptor >= 0 {
                        try unlinkIfNameBindsToDescriptor(
                            restoreDescriptor,
                            in: descriptors.parent,
                            name: restoreName
                        )
                    }
                    if rollbackDescriptor >= 0 {
                        try unlinkIfNameBindsToDescriptor(
                            rollbackDescriptor,
                            in: descriptors.parent,
                            name: rollbackName
                        )
                    }
                } catch {
                    throw DatabaseRecoveryError.restoreFailed
                }
                if error is CancellationError { throw error }
                if let recovery = error as? DatabaseRecoveryError { throw recovery }
                throw DatabaseRecoveryError.restoreFailed
            }

            do {
                guard let retainedRollbackIdentity else {
                    throw DatabaseRecoveryError.rollbackFailed
                }
                try await rollback(
                    snapshot: rollbackDescriptor,
                    snapshotIdentity: retainedRollbackIdentity,
                    snapshotName: rollbackName,
                    installName: rollbackInstallName,
                    in: descriptors.parent
                )
            } catch let rollbackError as DatabaseRecoveryError {
                if rollbackError == .restoreFailedCleanupPending { throw rollbackError }
                if rollbackError == .preservationFailed {
                    if let retainedRollbackIdentity {
                        do {
                            try retainPendingPreservation(
                                snapshot: rollbackDescriptor,
                                identity: retainedRollbackIdentity,
                                parent: descriptors.parent
                            )
                        } catch {
                            throw DatabaseRecoveryError.preservationFailed
                        }
                        throw DatabaseRecoveryError.preservationRetryRequired
                    }
                    throw rollbackError
                }
                throw DatabaseRecoveryError.rollbackFailed
            } catch {
                throw DatabaseRecoveryError.rollbackFailed
            }
            throw DatabaseRecoveryError.rollbackCompleted
        }
    }

    /// Re-materializes a descriptor-retained snapshot after a namespace
    /// preservation failure. This never reads or writes the live ledger.
    public func retryPreservation() throws {
        guard let pending = pendingPreservation else {
            throw DatabaseRecoveryError.preservationFailed
        }
        do {
            try ensureParentDirectoryBinding(pending.parent)
            guard try identity(of: pending.snapshot) == pending.identity else {
                throw DatabaseRecoveryError.preservationFailed
            }
            _ = try boundedByteCount(
                of: pending.snapshot,
                unsafe: .preservationFailed,
                allowUnlinked: true
            )
        } catch {
            pending.close()
            pendingPreservation = nil
            throw DatabaseRecoveryError.preservationFailed
        }
        let artifactName = ".tokenboard-recovery-pending-\(UUID().uuidString).sqlite"
        let artifact: Int32
        do {
            artifact = try createRegular(in: pending.parent, name: artifactName)
        } catch {
            throw DatabaseRecoveryError.preservationRetryRequired
        }
        var artifactIsVerified = false
        do {
            let digest = try copy(from: pending.snapshot, to: artifact)
            guard digest == pending.identity.digest,
                  try identity(of: pending.snapshot) == pending.identity,
                  fchmod(artifact, S_IRUSR) == 0,
                  fsync(artifact) == 0 else {
                throw DatabaseRecoveryError.preservationRetryRequired
            }
            let artifactIdentity = try identity(of: artifact)
            guard artifactIdentity.digest == pending.identity.digest,
                  artifactIdentity.size == pending.identity.size else {
                throw DatabaseRecoveryError.preservationRetryRequired
            }
            try fileOperationHandler(.syncPreservationArtifact)
            guard fsync(pending.parent) == 0 else { throw posixFailure() }
            try verifyRecoveryArtifact(
                artifact,
                expected: artifactIdentity,
                in: pending.parent,
                name: artifactName
            )
            artifactIsVerified = true
        } catch {
            let sourceIsStillValid = (try? identity(of: pending.snapshot)) == pending.identity
            if !artifactIsVerified {
                let removed = (try? unlinkIfNameBindsToDescriptor(
                    artifact,
                    in: pending.parent,
                    name: artifactName
                )) == true
                if removed { _ = fsync(pending.parent) }
            }
            Darwin.close(artifact)
            if !sourceIsStillValid {
                pending.close()
                pendingPreservation = nil
                throw DatabaseRecoveryError.preservationFailed
            }
            throw DatabaseRecoveryError.preservationRetryRequired
        }
        Darwin.close(artifact)
        do {
            try pruneRecoverySnapshots(
                in: pending.parent,
                preserving: artifactName
            )
        } catch {
            pending.close()
            pendingPreservation = nil
            throw DatabaseRecoveryError.cleanupPending
        }
        pending.close()
        pendingPreservation = nil
    }

    private func rollback(
        snapshot: Int32,
        snapshotIdentity: RecoveryFileIdentity,
        snapshotName: String,
        installName: String,
        in parent: Int32
    ) async throws {
        try await stageHandler(.beforeRollback)
        try ensureNameBindsToDescriptor(
            snapshot,
            expected: snapshotIdentity,
            in: parent,
            name: snapshotName,
            unsafe: .rollbackFailed
        )
        let install = try createRegular(in: parent, name: installName)
        defer { Darwin.close(install) }
        do {
            let copiedDigest = try copy(
                from: snapshot,
                to: install,
                operation: .rollbackCopyChunk,
                syncOperation: .syncRollbackInstall
            )
            guard copiedDigest == snapshotIdentity.digest,
                  try identity(of: snapshot) == snapshotIdentity else {
                throw DatabaseRecoveryError.rollbackFailed
            }
        } catch { throw error }
        let installIdentity = try identity(of: install)
        try ensureNameBindsToDescriptor(
            install,
            expected: installIdentity,
            in: parent,
            name: installName,
            unsafe: .rollbackFailed
        )
        try removeExactSidecars(in: parent, syncOperation: .syncBeforeRollback)
        guard renameat(parent, installName, parent, Self.databaseFilename) == 0 else {
            throw posixFailure()
        }
        try syncDirectory(parent, operation: .syncAfterRollback)
        try ensureNameBindsToDescriptor(
            install,
            expected: installIdentity,
            in: parent,
            name: Self.databaseFilename,
            unsafe: .rollbackFailed
        )
        guard installIdentity.digest == snapshotIdentity.digest else {
            throw DatabaseRecoveryError.rollbackFailed
        }
        try validateDatabase(on: install, expected: installIdentity)
        try await stageHandler(.afterRollback)
        try ensureNameBindsToDescriptor(
            install,
            expected: installIdentity,
            in: parent,
            name: Self.databaseFilename,
            unsafe: .rollbackFailed
        )
        do {
            try syncDirectory(parent, operation: .syncCleanup)
            try ensureNameBindsToDescriptor(
                install,
                expected: installIdentity,
                in: parent,
                name: Self.databaseFilename,
                unsafe: .rollbackFailed
            )
            try verifyRetainedRecoveryArtifact(
                snapshot,
                expected: snapshotIdentity,
                in: parent,
                name: snapshotName
            )
            try pruneRecoverySnapshots(in: parent, preserving: snapshotName)
        } catch let recovery as DatabaseRecoveryError where recovery == .preservationFailed {
            throw recovery
        } catch {
            do {
                try ensureNameBindsToDescriptor(
                    install,
                    expected: installIdentity,
                    in: parent,
                    name: Self.databaseFilename,
                    unsafe: .rollbackFailed
                )
            } catch {
                throw DatabaseRecoveryError.rollbackFailed
            }
            do {
                try verifyRetainedRecoveryArtifact(
                    snapshot,
                    expected: snapshotIdentity,
                    in: parent,
                    name: snapshotName
                )
            } catch {
                throw DatabaseRecoveryError.preservationFailed
            }
            throw DatabaseRecoveryError.restoreFailedCleanupPending
        }
    }

    private func prepareStagedDatabase(_ descriptor: Int32) async throws {
        try validateDatabase(on: descriptor)
        let byteCount = try boundedByteCount(of: descriptor, unsafe: .unsafeBackup)
        let connection = try SQLiteConnection.recoveryConnection(
            descriptor: descriptor,
            byteCount: byteCount,
            maximumBytes: maximumRecoveryImageBytes
        )
        let ledger = SQLiteLedger(
            recoveryConnection: connection,
            backupDirectory: backupDirectory
        )
        do {
            try await ledger.migrateForRecovery()
            try await ledger.integrityCheck()
            try await ledger.writeSerializedRecoveryDatabase(
                to: descriptor,
                maximumBytes: maximumRecoveryImageBytes
            )
            try await ledger.shutdown()
            try fileOperationHandler(.syncStagedRestore)
            guard fsync(descriptor) == 0 else { throw posixFailure() }
            try validateDatabase(on: descriptor)
        } catch let validationError {
            do {
                try await ledger.shutdown()
            } catch {
                throw error
            }
            throw validationError
        }
    }

    private func openConfirmedBackup(
        _ confirmed: DatabaseBackup,
        in backups: Int32
    ) throws -> Int32 {
        guard Self.isBackupFilename(confirmed.filename),
              confirmed.id == confirmed.identity.token(filename: confirmed.filename) else {
            throw DatabaseRecoveryError.backupChanged
        }
        let descriptor = try openRegular(
            in: backups,
            name: confirmed.filename,
            missing: .backupChanged,
            unsafe: .unsafeBackup
        )
        do {
            _ = try boundedByteCount(of: descriptor, unsafe: .unsafeBackup)
            guard try identity(of: descriptor) == confirmed.identity else {
                throw DatabaseRecoveryError.backupChanged
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func openDirectories(allowMissingBackups: Bool) throws -> RecoveryDirectories {
        guard hasValidLexicalNamespace else {
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
        let parent = try openDirectoryPathNoFollow(
            databaseURL.deletingLastPathComponent().path
        )
        let backups = openat(
            parent,
            Self.backupDirectoryName,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
        )
        if backups < 0 {
            if allowMissingBackups, errno == ENOENT {
                return RecoveryDirectories(parent: parent, backups: -1)
            }
            Darwin.close(parent)
            if errno == ENOENT { throw DatabaseRecoveryError.noBackupAvailable }
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
        return RecoveryDirectories(parent: parent, backups: backups)
    }

    private func openDirectoryPathNoFollow(_ path: String) throws -> Int32 {
        guard path.hasPrefix("/") else {
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
        do {
            for component in path.split(separator: "/").map(String.init) {
                guard Self.isSinglePathComponent(component) else {
                    throw DatabaseRecoveryError.invalidDatabaseLocation
                }
                let next = openat(
                    descriptor,
                    component,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
                guard next >= 0 else {
                    throw DatabaseRecoveryError.invalidDatabaseLocation
                }
                Darwin.close(descriptor)
                descriptor = next
            }
            return descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private func validateSidecars(in parent: Int32) throws {
        for name in Self.sidecarNames {
            var information = stat()
            if fstatat(parent, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { continue }
                throw DatabaseRecoveryError.unsafeSidecar
            }
            guard Self.isRegular(information), information.st_nlink == 1 else {
                throw DatabaseRecoveryError.unsafeSidecar
            }
        }
    }

    private func ensureParentDirectoryBinding(_ expectedDescriptor: Int32) throws {
        let current = try openDirectoryPathNoFollow(
            databaseURL.deletingLastPathComponent().path
        )
        defer { Darwin.close(current) }
        var expected = stat()
        var actual = stat()
        guard fstat(expectedDescriptor, &expected) == 0,
              fstat(current, &actual) == 0,
              expected.st_dev == actual.st_dev,
              expected.st_ino == actual.st_ino else {
            throw DatabaseRecoveryError.invalidDatabaseLocation
        }
    }

    private func removeExactSidecars(
        in parent: Int32,
        syncOperation: DatabaseRecoveryFileOperation
    ) throws {
        for name in Self.sidecarNames {
            do {
                try unlinkRegularIfPresent(
                    in: parent,
                    name: name,
                    operation: .removeSidecar
                )
            } catch {
                throw DatabaseRecoveryError.unsafeSidecar
            }
        }
        try syncDirectory(parent, operation: syncOperation)
    }

    private func openRegular(
        in directory: Int32,
        name: String,
        missing: DatabaseRecoveryError,
        unsafe: DatabaseRecoveryError
    ) throws -> Int32 {
        guard Self.isSinglePathComponent(name) else { throw unsafe }
        let descriptor = openat(
            directory,
            name,
            O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            if errno == ENOENT { throw missing }
            throw unsafe
        }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              Self.isRegular(information),
              information.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw unsafe
        }
        return descriptor
    }

    private func createRegular(in directory: Int32, name: String) throws -> Int32 {
        guard Self.isSinglePathComponent(name) else {
            throw DatabaseRecoveryError.restoreFailed
        }
        let descriptor = openat(
            directory,
            name,
            O_RDWR | O_NONBLOCK | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixFailure() }
        return descriptor
    }

    private func ensureNameBindsToDescriptor(
        _ descriptor: Int32,
        expected: RecoveryFileIdentity,
        in directory: Int32,
        name: String,
        unsafe: DatabaseRecoveryError
    ) throws {
        guard Self.isSinglePathComponent(name) else { throw unsafe }
        let currentIdentity: RecoveryFileIdentity
        do {
            currentIdentity = try identity(of: descriptor)
        } catch {
            throw unsafe
        }
        var descriptorInformation = stat()
        var nameInformation = stat()
        guard fstat(descriptor, &descriptorInformation) == 0,
              fstatat(directory, name, &nameInformation, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isRegular(descriptorInformation),
              Self.isRegular(nameInformation),
              descriptorInformation.st_nlink == 1,
              nameInformation.st_nlink == 1,
              RecoveryFileIdentity.sameMetadata(descriptorInformation, nameInformation),
              currentIdentity == expected,
              RecoveryFileIdentity(information: descriptorInformation, digest: currentIdentity.digest) == expected
        else { throw unsafe }
    }

    private func verifyFinalIdentity(
        _ descriptor: Int32,
        expected: RecoveryFileIdentity,
        in directory: Int32,
        name: String,
        unsafe: DatabaseRecoveryError
    ) throws {
        try ensureParentDirectoryBinding(directory)
        try ensureNameBindsToDescriptor(
            descriptor,
            expected: expected,
            in: directory,
            name: name,
            unsafe: unsafe
        )
    }

    private func verifyRecoveryArtifact(
        _ descriptor: Int32,
        expected: RecoveryFileIdentity,
        in directory: Int32,
        name: String
    ) throws {
        try ensureParentDirectoryBinding(directory)
        try verifyRetainedRecoveryArtifact(
            descriptor,
            expected: expected,
            in: directory,
            name: name
        )
    }

    private func verifyRetainedRecoveryArtifact(
        _ descriptor: Int32,
        expected: RecoveryFileIdentity,
        in directory: Int32,
        name: String
    ) throws {
        try ensureNameBindsToDescriptor(
            descriptor,
            expected: expected,
            in: directory,
            name: name,
            unsafe: .preservationFailed
        )
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_nlink == 1,
              information.st_mode & (S_IWUSR | S_IWGRP | S_IWOTH) == 0 else {
            throw DatabaseRecoveryError.preservationFailed
        }
    }

    private func retainPendingPreservation(
        snapshot: Int32,
        identity expected: RecoveryFileIdentity,
        parent: Int32
    ) throws {
        guard snapshot >= 0, try identity(of: snapshot) == expected else {
            throw DatabaseRecoveryError.preservationFailed
        }
        try fileOperationHandler(.retainSnapshotDescriptor)
        let retainedSnapshot = fcntl(snapshot, F_DUPFD_CLOEXEC, 0)
        guard retainedSnapshot >= 0 else { throw DatabaseRecoveryError.preservationFailed }
        let retainedParent: Int32
        do {
            try fileOperationHandler(.retainParentDescriptor)
            retainedParent = fcntl(parent, F_DUPFD_CLOEXEC, 0)
            guard retainedParent >= 0 else {
                throw DatabaseRecoveryError.preservationFailed
            }
        } catch {
            Darwin.close(retainedSnapshot)
            throw DatabaseRecoveryError.preservationFailed
        }
        pendingPreservation?.close()
        pendingPreservation = PendingRecoveryPreservation(
            snapshot: retainedSnapshot,
            identity: expected,
            parent: retainedParent
        )
    }

    private func boundedByteCount(
        of descriptor: Int32,
        unsafe: DatabaseRecoveryError,
        allowUnlinked: Bool = false
    ) throws -> Int {
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              Self.isRegular(before),
              (before.st_nlink == 1 || (allowUnlinked && before.st_nlink == 0)),
              before.st_size >= 0,
              let count = Int(exactly: before.st_size) else {
            throw unsafe
        }
        guard count <= maximumRecoveryImageBytes else {
            throw DatabaseRecoveryError.backupTooLarge(
                maximumBytes: maximumRecoveryImageBytes
            )
        }
        let (allocatedBytes, overflowed) = Int64(before.st_blocks).multipliedReportingOverflow(by: 512)
        guard !overflowed,
              count == 0 || allocatedBytes >= before.st_size else {
            throw unsafe
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              RecoveryFileIdentity.sameMetadata(before, after),
              (after.st_nlink == 1 || (allowUnlinked && after.st_nlink == 0)) else {
            throw unsafe
        }
        return count
    }

    private func unlinkRegularIfPresent(
        in directory: Int32,
        name: String,
        operation: DatabaseRecoveryFileOperation? = nil
    ) throws {
        guard Self.isSinglePathComponent(name) else { throw posixFailure(EINVAL) }
        var information = stat()
        if fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw posixFailure()
        }
        guard Self.isRegular(information), information.st_nlink == 1 else {
            throw DatabaseRecoveryError.unsafeSidecar
        }
        if let operation { try fileOperationHandler(operation) }
        guard unlinkat(directory, name, 0) == 0 else { throw posixFailure() }
    }

    @discardableResult
    private func unlinkIfNameBindsToDescriptor(
        _ descriptor: Int32,
        in directory: Int32,
        name: String
    ) throws -> Bool {
        guard Self.isSinglePathComponent(name) else { throw posixFailure(EINVAL) }
        var descriptorInformation = stat()
        var nameInformation = stat()
        if fstatat(directory, name, &nameInformation, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }
            throw posixFailure()
        }
        guard fstat(descriptor, &descriptorInformation) == 0,
              Self.isRegular(descriptorInformation),
              Self.isRegular(nameInformation),
              descriptorInformation.st_dev == nameInformation.st_dev,
              descriptorInformation.st_ino == nameInformation.st_ino else {
            return false
        }
        guard unlinkat(directory, name, 0) == 0 else { throw posixFailure() }
        return true
    }

    private func pruneRecoverySnapshots(
        in parent: Int32,
        preserving currentName: String
    ) throws {
        let names = try listNames(in: parent).filter(Self.isRecoverySnapshotName)
        var candidates: [RecoverySnapshotCandidate] = []
        for name in names {
            guard let descriptor = try? openRegular(
                in: parent,
                name: name,
                missing: .cleanupPending,
                unsafe: .cleanupPending
            ) else { continue }
            defer { Darwin.close(descriptor) }
            guard let identity = try? identity(of: descriptor) else { continue }
            candidates.append(RecoverySnapshotCandidate(name: name, identity: identity))
        }
        let newestOther = candidates
            .filter { $0.name != currentName }
            .sorted { lhs, rhs in
                if lhs.identity.modificationSeconds != rhs.identity.modificationSeconds {
                    return lhs.identity.modificationSeconds > rhs.identity.modificationSeconds
                }
                if lhs.identity.modificationNanoseconds != rhs.identity.modificationNanoseconds {
                    return lhs.identity.modificationNanoseconds > rhs.identity.modificationNanoseconds
                }
                return lhs.name > rhs.name
            }
            .first
        var preserved = Set([currentName])
        if let newestOther { preserved.insert(newestOther.name) }
        var removedAny = false
        for candidate in candidates where !preserved.contains(candidate.name) {
            let descriptor = try openRegular(
                in: parent,
                name: candidate.name,
                missing: .cleanupPending,
                unsafe: .cleanupPending
            )
            defer { Darwin.close(descriptor) }
            try ensureNameBindsToDescriptor(
                descriptor,
                expected: candidate.identity,
                in: parent,
                name: candidate.name,
                unsafe: .cleanupPending
            )
            removedAny = try unlinkIfNameBindsToDescriptor(
                descriptor,
                in: parent,
                name: candidate.name
            ) || removedAny
        }
        if removedAny {
            try syncDirectory(parent, operation: .syncSnapshotPruning)
        }
    }

    private func listNames(in directory: Int32) throws -> [String] {
        let duplicate = dup(directory)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw posixFailure()
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    private func identity(of descriptor: Int32) throws -> RecoveryFileIdentity {
        var before = stat()
        guard fstat(descriptor, &before) == 0, Self.isRegular(before) else {
            throw posixFailure()
        }
        let digest = try digest(of: descriptor)
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              RecoveryFileIdentity.sameMetadata(before, after) else {
            throw DatabaseRecoveryError.backupChanged
        }
        return RecoveryFileIdentity(information: after, digest: digest)
    }

    private func digest(of descriptor: Int32) throws -> String {
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixFailure() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw posixFailure()
            }
            hasher.update(data: Data(buffer[0..<count]))
        }
        guard lseek(descriptor, 0, SEEK_SET) >= 0 else { throw posixFailure() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func copy(
        from source: Int32,
        to destination: Int32,
        operation: DatabaseRecoveryFileOperation? = nil,
        syncOperation: DatabaseRecoveryFileOperation? = nil
    ) throws -> String {
        guard lseek(source, 0, SEEK_SET) >= 0 else { throw posixFailure() }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(source, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw posixFailure()
            }
            hasher.update(data: Data(buffer[0..<count]))
            var written = 0
            while written < count {
                let result = buffer.withUnsafeBytes { bytes in
                    Darwin.write(
                        destination,
                        bytes.baseAddress!.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw posixFailure()
                }
                written += result
                if let operation { try fileOperationHandler(operation) }
            }
        }
        if let syncOperation { try fileOperationHandler(syncOperation) }
        guard fsync(destination) == 0 else { throw posixFailure() }
        guard lseek(source, 0, SEEK_SET) >= 0 else { throw posixFailure() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func validateDatabase(
        on descriptor: Int32,
        expected: RecoveryFileIdentity? = nil
    ) throws {
        let before = try identity(of: descriptor)
        if let expected, before != expected { throw DatabaseRecoveryError.restoreFailed }
        let connection = try SQLiteConnection.immutableDescriptor(descriptor)
        do {
            let rows = try connection.queryStrings("PRAGMA quick_check;")
            guard rows == ["ok"] else {
                throw LedgerError.integrityCheckFailed(rows.joined(separator: "; "))
            }
            try connection.close()
        } catch {
            try? connection.close()
            throw error
        }
        guard try identity(of: descriptor) == before else {
            throw DatabaseRecoveryError.restoreFailed
        }
    }

    private func syncDirectory(
        _ descriptor: Int32,
        operation: DatabaseRecoveryFileOperation
    ) throws {
        try fileOperationHandler(operation)
        guard fsync(descriptor) == 0 else { throw posixFailure() }
    }

    private func posixFailure(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    private static func isBackupFilename(_ filename: String) -> Bool {
        let range = NSRange(filename.startIndex..<filename.endIndex, in: filename)
        return backupPattern.firstMatch(in: filename, range: range)?.range == range
    }

    private static func canonicalSystemURL(_ url: URL) -> URL {
        let path = url.path
        if path == "/var" || path.hasPrefix("/var/")
            || path == "/tmp" || path.hasPrefix("/tmp/") {
            return URL(fileURLWithPath: "/private" + path)
        }
        return url
    }

    private static func isSinglePathComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
    }

    private static func isRecoverySnapshotName(_ name: String) -> Bool {
        (name.hasPrefix(".tokenboard-pre-restore-")
            || name.hasPrefix(".tokenboard-recovery-pending-"))
            && name.hasSuffix(".sqlite")
            && isSinglePathComponent(name)
    }

    private static func isRegular(_ information: stat) -> Bool {
        information.st_mode & S_IFMT == S_IFREG
    }
}

private struct RecoveryDirectories {
    let parent: Int32
    let backups: Int32

    func close() {
        if backups >= 0 { Darwin.close(backups) }
        Darwin.close(parent)
    }
}

private struct PendingRecoveryPreservation {
    let snapshot: Int32
    let identity: RecoveryFileIdentity
    let parent: Int32

    func close() {
        Darwin.close(snapshot)
        Darwin.close(parent)
    }
}

private struct RecoverySnapshotCandidate {
    let name: String
    let identity: RecoveryFileIdentity
}

private struct RecoveryFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let digest: String

    init(information: stat, digest: String) {
        device = UInt64(information.st_dev)
        inode = UInt64(information.st_ino)
        size = information.st_size
        modificationSeconds = Int64(information.st_mtimespec.tv_sec)
        modificationNanoseconds = Int64(information.st_mtimespec.tv_nsec)
        self.digest = digest
    }

    var modificationDate: Date {
        Date(
            timeIntervalSince1970: TimeInterval(modificationSeconds)
                + TimeInterval(modificationNanoseconds) / 1_000_000_000
        )
    }

    func token(filename: String) -> String {
        let value = "\(filename)|\(device)|\(inode)|\(size)|\(modificationSeconds)|\(modificationNanoseconds)|\(digest)"
        return SHA256.hash(data: Data(value.utf8)).map {
            String(format: "%02x", $0)
        }.joined()
    }

    static func sameMetadata(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev
            && lhs.st_ino == rhs.st_ino
            && lhs.st_size == rhs.st_size
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
    }
}
