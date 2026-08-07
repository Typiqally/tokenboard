import CryptoKit
import Darwin
import Foundation

public struct DatabaseBackup: Equatable, Sendable {
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
}

public actor DatabaseRecoveryService {
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
    private var restoreInProgress = false

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
    }

    init(
        databaseURL: URL,
        backupDirectory: URL,
        stageHandler: @escaping @Sendable (DatabaseRecoveryStage) async throws -> Void,
        fileOperationHandler: @escaping @Sendable (DatabaseRecoveryFileOperation) throws -> Void = { _ in }
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
    }

    public func availableBackups() throws -> [DatabaseBackup] {
        let descriptors = try openDirectories(allowMissingBackups: true)
        defer { descriptors.close() }
        guard descriptors.backups >= 0 else { return [] }

        return try listNames(in: descriptors.backups).compactMap { filename in
            guard Self.isBackupFilename(filename) else { return nil }
            let descriptor: Int32
            do {
                descriptor = try openRegular(
                    in: descriptors.backups,
                    name: filename,
                    missing: .unsafeBackup,
                    unsafe: .unsafeBackup
                )
            } catch DatabaseRecoveryError.unsafeBackup {
                return nil
            }
            defer { Darwin.close(descriptor) }
            return DatabaseBackup(
                filename: filename,
                identity: try identity(of: descriptor)
            )
        }.sorted { lhs, rhs in
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

        do {
            let restoreDescriptor = try createRegular(in: descriptors.parent, name: restoreName)
            do {
                let copiedDigest = try copy(
                    from: backupDescriptor,
                    to: restoreDescriptor,
                    operation: .restoreCopyChunk
                )
                guard copiedDigest == confirmedBackup.identity.digest,
                      try identity(of: backupDescriptor) == confirmedBackup.identity else {
                    throw DatabaseRecoveryError.backupChanged
                }
            } catch {
                Darwin.close(restoreDescriptor)
                throw error
            }
            try closeChecked(restoreDescriptor)

            let databaseIdentity = try identity(of: databaseDescriptor)
            let rollbackDescriptor = try createRegular(in: descriptors.parent, name: rollbackName)
            do {
                let copiedDigest = try copy(
                    from: databaseDescriptor,
                    to: rollbackDescriptor
                )
                guard copiedDigest == databaseIdentity.digest,
                      try identity(of: databaseDescriptor) == databaseIdentity else {
                    throw DatabaseRecoveryError.unsafeDatabase
                }
                guard fchmod(rollbackDescriptor, S_IRUSR) == 0 else {
                    throw posixFailure()
                }
            } catch {
                Darwin.close(rollbackDescriptor)
                throw error
            }
            try closeChecked(rollbackDescriptor)

            try await stageHandler(.beforeReplacement)
            try Task.checkCancellation()
            try ensureCurrentIdentity(
                databaseIdentity,
                in: descriptors.parent,
                name: Self.databaseFilename,
                unsafe: .unsafeDatabase
            )
            replacementBegan = true
            guard renameat(
                descriptors.parent,
                restoreName,
                descriptors.parent,
                Self.databaseFilename
            ) == 0 else { throw posixFailure() }
            try syncDirectory(descriptors.parent)
            try removeExactSidecars(in: descriptors.parent)
            try await stageHandler(.afterReplacement)
            try Task.checkCancellation()
            try await validateRestoredDatabase()
            try await stageHandler(.afterValidation)
            try Task.checkCancellation()
            try removeExactSidecars(in: descriptors.parent)
            try unlinkRegularIfPresent(in: descriptors.parent, name: rollbackName)
            try syncDirectory(descriptors.parent)
            return confirmedBackup
        } catch {
            guard replacementBegan else {
                do {
                    try unlinkRegularIfPresent(in: descriptors.parent, name: restoreName)
                    try unlinkRegularIfPresent(in: descriptors.parent, name: rollbackName)
                } catch {
                    throw DatabaseRecoveryError.restoreFailed
                }
                if error is CancellationError { throw error }
                if let recovery = error as? DatabaseRecoveryError { throw recovery }
                throw DatabaseRecoveryError.restoreFailed
            }

            do {
                try await rollback(
                    snapshotName: rollbackName,
                    installName: rollbackInstallName,
                    in: descriptors.parent
                )
            } catch {
                throw DatabaseRecoveryError.rollbackFailed
            }
            do {
                try unlinkRegularIfPresent(in: descriptors.parent, name: restoreName)
            } catch {
                throw DatabaseRecoveryError.restoreFailed
            }
            if error is CancellationError { throw error }
            throw DatabaseRecoveryError.restoreFailed
        }
    }

    private func rollback(
        snapshotName: String,
        installName: String,
        in parent: Int32
    ) async throws {
        try await stageHandler(.beforeRollback)
        let snapshot = try openRegular(
            in: parent,
            name: snapshotName,
            missing: .rollbackFailed,
            unsafe: .rollbackFailed
        )
        defer { Darwin.close(snapshot) }
        let snapshotIdentity = try identity(of: snapshot)
        let install = try createRegular(in: parent, name: installName)
        do {
            let copiedDigest = try copy(
                from: snapshot,
                to: install,
                operation: .rollbackCopyChunk
            )
            guard copiedDigest == snapshotIdentity.digest,
                  try identity(of: snapshot) == snapshotIdentity else {
                throw DatabaseRecoveryError.rollbackFailed
            }
        } catch {
            Darwin.close(install)
            throw error
        }
        try closeChecked(install)
        guard renameat(parent, installName, parent, Self.databaseFilename) == 0 else {
            throw posixFailure()
        }
        try syncDirectory(parent)
        try removeExactSidecars(in: parent)
        let restored = try openRegular(
            in: parent,
            name: Self.databaseFilename,
            missing: .rollbackFailed,
            unsafe: .rollbackFailed
        )
        defer { Darwin.close(restored) }
        guard try identity(of: restored).digest == snapshotIdentity.digest else {
            throw DatabaseRecoveryError.rollbackFailed
        }
        try await stageHandler(.afterRollback)
        try unlinkRegularIfPresent(in: parent, name: snapshotName)
        try syncDirectory(parent)
    }

    private func validateRestoredDatabase() async throws {
        let ledger = try SQLiteLedger(
            databaseURL: databaseURL,
            backupDirectory: backupDirectory
        )
        do {
            try await ledger.migrateForRecovery()
            try await ledger.integrityCheck()
            try await ledger.shutdown()
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

    private func removeExactSidecars(in parent: Int32) throws {
        for name in Self.sidecarNames {
            do {
                try unlinkRegularIfPresent(in: parent, name: name)
            } catch {
                throw DatabaseRecoveryError.unsafeSidecar
            }
        }
        try syncDirectory(parent)
    }

    private func openRegular(
        in directory: Int32,
        name: String,
        missing: DatabaseRecoveryError,
        unsafe: DatabaseRecoveryError
    ) throws -> Int32 {
        guard Self.isSinglePathComponent(name) else { throw unsafe }
        let descriptor = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
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
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixFailure() }
        return descriptor
    }

    private func ensureCurrentIdentity(
        _ expected: RecoveryFileIdentity,
        in directory: Int32,
        name: String,
        unsafe: DatabaseRecoveryError
    ) throws {
        let descriptor = try openRegular(
            in: directory,
            name: name,
            missing: unsafe,
            unsafe: unsafe
        )
        defer { Darwin.close(descriptor) }
        guard try identity(of: descriptor) == expected else { throw unsafe }
    }

    private func unlinkRegularIfPresent(in directory: Int32, name: String) throws {
        guard Self.isSinglePathComponent(name) else { throw posixFailure(EINVAL) }
        var information = stat()
        if fstatat(directory, name, &information, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return }
            throw posixFailure()
        }
        guard Self.isRegular(information), information.st_nlink == 1 else {
            throw DatabaseRecoveryError.unsafeSidecar
        }
        guard unlinkat(directory, name, 0) == 0 else { throw posixFailure() }
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
        operation: DatabaseRecoveryFileOperation? = nil
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
        guard fsync(destination) == 0 else { throw posixFailure() }
        guard lseek(source, 0, SEEK_SET) >= 0 else { throw posixFailure() }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func closeChecked(_ descriptor: Int32) throws {
        guard Darwin.close(descriptor) == 0 else { throw posixFailure() }
    }

    private func syncDirectory(_ descriptor: Int32) throws {
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
