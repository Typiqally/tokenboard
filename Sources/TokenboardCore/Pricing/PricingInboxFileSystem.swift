import Darwin
import Foundation

enum PricingInboxDirectory: Equatable, Sendable {
    case pricing
    case inbox
    case applied
    case rejected
}

struct PricingInboxFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct PricingInboxOpenedFile: Sendable {
    let data: Data
    let identity: PricingInboxFileIdentity
}

protocol PricingInboxFileSystem: AnyObject, Sendable {
    func open(rootPath: String) throws
    func close()
    func duplicateInboxDescriptor() throws -> Int32
    func readIfPresent(in directory: PricingInboxDirectory, name: String) throws -> PricingInboxOpenedFile?
    func listInbox() throws -> [String]
    func moveInbox(from: String, to: String, exclusive: Bool) throws
    func replaceCanonical(_ data: Data, in directory: PricingInboxDirectory, name: String) throws
    func installCanonicalIfAbsent(
        _ data: Data,
        in directory: PricingInboxDirectory,
        name: String
    ) throws -> Bool
    func removeInbox(name: String) throws
}

final class POSIXPricingInboxFileSystem: PricingInboxFileSystem, @unchecked Sendable {
    private struct Handles {
        let pricing: Int32
        let inbox: Int32
        let applied: Int32
        let rejected: Int32
    }

    private let lock = NSLock()
    private var handles: Handles?

    deinit { close() }

    func open(rootPath: String) throws {
        guard rootPath.hasPrefix("/"), !rootPath.utf8.contains(0) else {
            throw PricingInboxError.invalidApplicationSupportDirectory
        }
        if lock.withLock({ handles != nil }) { return }

        if !FileManager.default.fileExists(atPath: rootPath) {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: rootPath, isDirectory: true),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PricingInboxError.fileOperationFailed("could not create application support directory")
            }
        }

        let root = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else { throw PricingInboxError.insecureManagedDirectory("Application Support") }
        defer { Darwin.close(root) }
        var rootStatus = stat()
        guard fstat(root, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR,
              rootStatus.st_uid == geteuid() else {
            throw PricingInboxError.insecureManagedDirectory("Application Support")
        }

        var opened: [Int32] = []
        do {
            let pricing = try createAndOpenDirectory(parent: root, name: "Pricing")
            opened.append(pricing)
            let inbox = try createAndOpenDirectory(parent: pricing, name: "Inbox")
            opened.append(inbox)
            let applied = try createAndOpenDirectory(parent: pricing, name: "Applied")
            opened.append(applied)
            let rejected = try createAndOpenDirectory(parent: pricing, name: "Rejected")
            opened.append(rejected)
            let newHandles = Handles(pricing: pricing, inbox: inbox, applied: applied, rejected: rejected)
            let installed = lock.withLock { () -> Bool in
                guard handles == nil else { return false }
                handles = newHandles
                return true
            }
            if !installed { opened.forEach { Darwin.close($0) } }
        } catch {
            opened.forEach { Darwin.close($0) }
            throw error
        }
    }

    func close() {
        let closing = lock.withLock { () -> Handles? in
            defer { handles = nil }
            return handles
        }
        guard let closing else { return }
        Darwin.close(closing.rejected)
        Darwin.close(closing.applied)
        Darwin.close(closing.inbox)
        Darwin.close(closing.pricing)
    }

    func duplicateInboxDescriptor() throws -> Int32 {
        let descriptor = try descriptor(for: .inbox)
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw PricingInboxError.couldNotMonitorInbox(errno)
        }
        return duplicate
    }

    func readIfPresent(
        in directory: PricingInboxDirectory,
        name: String
    ) throws -> PricingInboxOpenedFile? {
        try validate(name: name)
        let directoryDescriptor = try descriptor(for: directory)
        let file = openat(directoryDescriptor, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        defer { Darwin.close(file) }

        var status = stat()
        guard fstat(file, &status) == 0 else {
            throw PricingInboxError.candidateUnavailable
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PricingInboxError.candidateNotRegularFile
        }
        guard status.st_nlink == 1 else {
            throw PricingInboxError.candidateHasMultipleLinks
        }
        guard status.st_size >= 0, status.st_size <= 1_048_576 else {
            throw PricingInboxError.candidateTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PricingInboxError.candidateUnavailable
            }
            guard data.count + count <= 1_048_576 else {
                throw PricingInboxError.candidateTooLarge
            }
            data.append(buffer, count: count)
        }
        return PricingInboxOpenedFile(
            data: data,
            identity: PricingInboxFileIdentity(device: UInt64(status.st_dev), inode: UInt64(status.st_ino))
        )
    }

    func listInbox() throws -> [String] {
        let inbox = try descriptor(for: .inbox)
        let duplicate = fcntl(inbox, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0, let directory = fdopendir(duplicate) else {
            if duplicate >= 0 { Darwin.close(duplicate) }
            throw PricingInboxError.fileOperationFailed("could not enumerate inbox")
        }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name != ".", name != ".." { names.append(name) }
        }
        return names.sorted()
    }

    func moveInbox(from: String, to: String, exclusive: Bool) throws {
        try validate(name: from)
        try validate(name: to)
        let inbox = try descriptor(for: .inbox)
        let result: Int32
        if exclusive {
            result = renameatx_np(inbox, from, inbox, to, UInt32(RENAME_EXCL))
        } else {
            result = renameat(inbox, from, inbox, to)
        }
        guard result == 0 else { throw PricingInboxError.candidateUnavailable }
        try sync(directory: inbox)
    }

    func replaceCanonical(_ data: Data, in directory: PricingInboxDirectory, name: String) throws {
        try validate(name: name)
        let directoryDescriptor = try descriptor(for: directory)
        try requireAbsentOrRegular(directory: directoryDescriptor, name: name)
        let temporary = try writeTemporaryCanonical(data, directory: directoryDescriptor)
        var installed = false
        defer { if !installed { _ = unlinkat(directoryDescriptor, temporary, 0) } }
        guard renameat(directoryDescriptor, temporary, directoryDescriptor, name) == 0 else {
            throw PricingInboxError.fileOperationFailed("could not replace canonical file")
        }
        installed = true
        try sync(directory: directoryDescriptor)
    }

    func installCanonicalIfAbsent(
        _ data: Data,
        in directory: PricingInboxDirectory,
        name: String
    ) throws -> Bool {
        try validate(name: name)
        let directoryDescriptor = try descriptor(for: directory)
        let temporary = try writeTemporaryCanonical(data, directory: directoryDescriptor)
        var installed = false
        defer { if !installed { _ = unlinkat(directoryDescriptor, temporary, 0) } }
        let result = renameatx_np(
            directoryDescriptor,
            temporary,
            directoryDescriptor,
            name,
            UInt32(RENAME_EXCL)
        )
        if result != 0, errno == EEXIST { return false }
        guard result == 0 else {
            throw PricingInboxError.fileOperationFailed("could not install canonical file")
        }
        installed = true
        try sync(directory: directoryDescriptor)
        return true
    }

    func removeInbox(name: String) throws {
        try validate(name: name)
        let inbox = try descriptor(for: .inbox)
        if unlinkat(inbox, name, 0) != 0, errno != ENOENT {
            throw PricingInboxError.fileOperationFailed("could not remove processed candidate")
        }
        try sync(directory: inbox)
    }

    private func createAndOpenDirectory(parent: Int32, name: String) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw PricingInboxError.fileOperationFailed("could not create managed directory")
        }
        let directory = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else {
            throw PricingInboxError.insecureManagedDirectory(name)
        }
        var status = stat()
        guard fstat(directory, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid() else {
            Darwin.close(directory)
            throw PricingInboxError.insecureManagedDirectory(name)
        }
        return directory
    }

    private func descriptor(for directory: PricingInboxDirectory) throws -> Int32 {
        try lock.withLock {
            guard let handles else { throw PricingInboxError.fileOperationFailed("pricing directories are closed") }
            switch directory {
            case .pricing: return handles.pricing
            case .inbox: return handles.inbox
            case .applied: return handles.applied
            case .rejected: return handles.rejected
            }
        }
    }

    private func validate(name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= Int(NAME_MAX),
              !name.utf8.contains(0),
              !name.contains("/") else {
            throw PricingInboxError.fileOperationFailed("invalid managed filename")
        }
    }

    private func requireAbsentOrRegular(directory: Int32, name: String) throws {
        var status = stat()
        if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
                throw PricingInboxError.fileOperationFailed("canonical destination is not a regular file")
            }
        } else if errno != ENOENT {
            throw PricingInboxError.fileOperationFailed("could not inspect canonical destination")
        }
    }

    private func writeTemporaryCanonical(_ data: Data, directory: Int32) throws -> String {
        let name = ".tokenboard-canonical-\(UUID().uuidString).tmp"
        let file = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard file >= 0 else {
            throw PricingInboxError.fileOperationFailed("could not create canonical temporary file")
        }
        var shouldRemove = true
        defer {
            Darwin.close(file)
            if shouldRemove { _ = unlinkat(directory, name, 0) }
        }
        try data.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let result = Darwin.write(
                    file,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset
                )
                if result < 0, errno == EINTR { continue }
                guard result > 0 else {
                    throw PricingInboxError.fileOperationFailed("could not write canonical temporary file")
                }
                offset += result
            }
        }
        guard fsync(file) == 0 else {
            throw PricingInboxError.fileOperationFailed("could not sync canonical temporary file")
        }
        shouldRemove = false
        return name
    }

    private func sync(directory: Int32) throws {
        guard fsync(directory) == 0 else {
            throw PricingInboxError.fileOperationFailed("could not sync managed directory")
        }
    }
}
