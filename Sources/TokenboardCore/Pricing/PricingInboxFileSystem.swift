import Darwin
import Foundation

struct PricingCatalogOpenedFile: Sendable {
    let data: Data
}

protocol PricingCatalogFileSystem: AnyObject, Sendable {
    func open(rootPath: String) throws
    func close()
    func duplicatePricingDescriptor() throws -> Int32
    func readIfPresent(name: String) throws -> PricingCatalogOpenedFile?
    func replaceCanonical(_ data: Data, name: String) throws
    func installCanonicalIfAbsent(_ data: Data, name: String) throws -> Bool
}

final class POSIXPricingCatalogFileSystem: PricingCatalogFileSystem, @unchecked Sendable {
    private let lock = NSLock()
    private let directorySync: @Sendable (Int32) -> Int32
    private var pricingDescriptor: Int32?

    init(directorySync: @escaping @Sendable (Int32) -> Int32 = { Darwin.fsync($0) }) {
        self.directorySync = directorySync
    }

    deinit { close() }

    func open(rootPath: String) throws {
        guard rootPath.hasPrefix("/"), !rootPath.utf8.contains(0) else {
            throw PricingCatalogError.invalidApplicationSupportDirectory
        }
        if lock.withLock({ pricingDescriptor != nil }) { return }

        if !FileManager.default.fileExists(atPath: rootPath) {
            do {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: rootPath, isDirectory: true),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw PricingCatalogError.fileOperationFailed(
                    "could not create application support directory"
                )
            }
        }

        let root = Darwin.open(rootPath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard root >= 0 else {
            throw PricingCatalogError.insecureManagedDirectory("Application Support")
        }
        defer { Darwin.close(root) }
        var rootStatus = stat()
        guard fstat(root, &rootStatus) == 0,
              rootStatus.st_mode & S_IFMT == S_IFDIR,
              rootStatus.st_uid == geteuid() else {
            throw PricingCatalogError.insecureManagedDirectory("Application Support")
        }

        let pricing = try createAndOpenDirectory(parent: root, name: "Pricing")
        let installed = lock.withLock { () -> Bool in
            guard pricingDescriptor == nil else { return false }
            pricingDescriptor = pricing
            return true
        }
        if !installed { Darwin.close(pricing) }
    }

    func close() {
        let closing = lock.withLock { () -> Int32? in
            defer { pricingDescriptor = nil }
            return pricingDescriptor
        }
        if let closing { Darwin.close(closing) }
    }

    func duplicatePricingDescriptor() throws -> Int32 {
        let descriptor = try pricing()
        let duplicate = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
        guard duplicate >= 0 else {
            throw PricingCatalogError.couldNotMonitor(errno)
        }
        return duplicate
    }

    func readIfPresent(name: String) throws -> PricingCatalogOpenedFile? {
        try validate(name: name)
        let directory = try pricing()
        let file = openat(directory, name, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        if file < 0, errno == ENOENT { return nil }
        guard file >= 0 else { throw PricingCatalogError.catalogUnavailable }
        defer { Darwin.close(file) }

        var status = stat()
        guard fstat(file, &status) == 0 else {
            throw PricingCatalogError.catalogUnavailable
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw PricingCatalogError.catalogNotRegularFile
        }
        guard status.st_nlink == 1 else {
            throw PricingCatalogError.catalogHasMultipleLinks
        }
        guard status.st_size >= 0, status.st_size <= 1_048_576 else {
            throw PricingCatalogError.catalogTooLarge
        }

        var data = Data()
        data.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw PricingCatalogError.catalogUnavailable
            }
            guard data.count + count <= 1_048_576 else {
                throw PricingCatalogError.catalogTooLarge
            }
            data.append(buffer, count: count)
        }
        return PricingCatalogOpenedFile(data: data)
    }

    func replaceCanonical(_ data: Data, name: String) throws {
        try validate(name: name)
        let directory = try pricing()
        try requireAbsentOrRegular(directory: directory, name: name)
        let temporary = try writeTemporaryCanonical(data, directory: directory)
        var installed = false
        defer { if !installed { _ = unlinkat(directory, temporary, 0) } }
        guard renameat(directory, temporary, directory, name) == 0 else {
            throw PricingCatalogError.fileOperationFailed("could not replace pricing catalog")
        }
        installed = true
        try sync(directory: directory)
    }

    func installCanonicalIfAbsent(_ data: Data, name: String) throws -> Bool {
        try validate(name: name)
        let directory = try pricing()
        let temporary = try writeTemporaryCanonical(data, directory: directory)
        var installed = false
        defer { if !installed { _ = unlinkat(directory, temporary, 0) } }
        if renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) != 0 {
            if errno == EEXIST { return false }
            throw PricingCatalogError.fileOperationFailed("could not install pricing catalog")
        }
        installed = true
        try sync(directory: directory)
        return true
    }

    private func createAndOpenDirectory(parent: Int32, name: String) throws -> Int32 {
        if mkdirat(parent, name, mode_t(0o700)) != 0, errno != EEXIST {
            throw PricingCatalogError.insecureManagedDirectory(name)
        }
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw PricingCatalogError.insecureManagedDirectory(name)
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR,
              status.st_uid == geteuid() else {
            Darwin.close(descriptor)
            throw PricingCatalogError.insecureManagedDirectory(name)
        }
        return descriptor
    }

    private func pricing() throws -> Int32 {
        guard let descriptor = lock.withLock({ pricingDescriptor }) else {
            throw PricingCatalogError.fileOperationFailed("pricing catalog is not open")
        }
        return descriptor
    }

    private func validate(name: String) throws {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              name.utf8.count <= Int(NAME_MAX),
              !name.utf8.contains(0),
              !name.contains("/") else {
            throw PricingCatalogError.fileOperationFailed("invalid managed filename")
        }
    }

    private func requireAbsentOrRegular(directory: Int32, name: String) throws {
        var status = stat()
        if fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) == 0 {
            guard status.st_mode & S_IFMT == S_IFREG, status.st_nlink == 1 else {
                throw PricingCatalogError.fileOperationFailed(
                    "pricing catalog destination is not a regular file"
                )
            }
        } else if errno != ENOENT {
            throw PricingCatalogError.fileOperationFailed("could not inspect pricing catalog")
        }
    }

    private func writeTemporaryCanonical(_ data: Data, directory: Int32) throws -> String {
        let name = ".tokenboard-pricing-\(UUID().uuidString).tmp"
        let file = openat(
            directory,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            mode_t(0o600)
        )
        guard file >= 0 else {
            throw PricingCatalogError.fileOperationFailed("could not create temporary catalog")
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
                    throw PricingCatalogError.fileOperationFailed("could not write temporary catalog")
                }
                offset += result
            }
        }
        guard fsync(file) == 0 else {
            throw PricingCatalogError.fileOperationFailed("could not sync temporary catalog")
        }
        shouldRemove = false
        return name
    }

    private func sync(directory: Int32) throws {
        guard directorySync(directory) == 0 else {
            throw PricingCatalogError.fileOperationFailed("could not sync pricing directory")
        }
    }
}
