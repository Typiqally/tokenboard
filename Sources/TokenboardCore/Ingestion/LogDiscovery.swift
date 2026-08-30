import Foundation

public enum LogDiscoveryError: Error, Equatable, Sendable {
    case inaccessibleRoot(URL)
    case inaccessibleEntry(URL)
}

public protocol LogDiscovering: Sendable {
    func jsonlFiles(under root: URL) throws -> [URL]
    func enumerateJSONLFiles(
        under root: URL,
        maximumChunkSize: Int,
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws
}

public extension LogDiscovering {
    func enumerateJSONLFiles(
        under root: URL,
        maximumChunkSize: Int,
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws {
        precondition(maximumChunkSize > 0)
        let files = try jsonlFiles(under: root)
        var start = files.startIndex
        while start < files.endIndex {
            try Task.checkCancellation()
            let end = files.index(
                start,
                offsetBy: maximumChunkSize,
                limitedBy: files.endIndex
            ) ?? files.endIndex
            try await consume(Array(files[start..<end]))
            start = end
        }
    }
}

public struct LogDiscovery: LogDiscovering, Sendable {
    public init() {}

    public func jsonlFiles(under root: URL) throws -> [URL] {
        let inventory = try makeInventory(under: root)

        var files: [URL] = []
        while let url = inventory.enumerator.nextObject() as? URL {
            if try isJSONLFile(url) { files.append(url.standardizedFileURL) }
        }
        try inventory.failure.throwIfPresent()
        return files.sorted { $0.path < $1.path }
    }

    public func enumerateJSONLFiles(
        under root: URL,
        maximumChunkSize: Int,
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws {
        precondition(maximumChunkSize > 0)
        let inventory = try makeInventory(under: root)

        var chunk: [URL] = []
        chunk.reserveCapacity(maximumChunkSize)
        while let url = inventory.enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard try isJSONLFile(url) else { continue }
            chunk.append(url.standardizedFileURL)
            if chunk.count == maximumChunkSize {
                try await consume(chunk.sorted { $0.path < $1.path })
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        try inventory.failure.throwIfPresent()
        if !chunk.isEmpty {
            try await consume(chunk.sorted { $0.path < $1.path })
        }
    }

    private func makeInventory(under root: URL) throws -> Inventory {
        let rootValues: URLResourceValues
        do {
            rootValues = try root.resourceValues(forKeys: [.isDirectoryKey])
        } catch {
            throw LogDiscoveryError.inaccessibleRoot(root.standardizedFileURL)
        }
        guard rootValues.isDirectory == true else {
            throw LogDiscoveryError.inaccessibleRoot(root.standardizedFileURL)
        }

        let failure = EnumerationFailure()
        let keys = Array(Self.inventoryResourceKeys)
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                failure.record(.inaccessibleEntry(url.standardizedFileURL))
                return false
            }
        ) else {
            throw LogDiscoveryError.inaccessibleRoot(root.standardizedFileURL)
        }
        return Inventory(enumerator: enumerator, failure: failure)
    }

    private func isJSONLFile(_ url: URL) throws -> Bool {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: Self.inventoryResourceKeys)
        } catch {
            throw LogDiscoveryError.inaccessibleEntry(url.standardizedFileURL)
        }
        return values.isSymbolicLink != true
            && values.isRegularFile == true
            && url.pathExtension.lowercased() == "jsonl"
    }

    private static let inventoryResourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey,
        .isSymbolicLinkKey
    ]
}

private struct Inventory {
    let enumerator: FileManager.DirectoryEnumerator
    let failure: EnumerationFailure
}

private final class EnumerationFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: LogDiscoveryError?

    func record(_ error: LogDiscoveryError) {
        lock.withLock {
            if self.error == nil { self.error = error }
        }
    }

    func throwIfPresent() throws {
        if let error = lock.withLock({ error }) { throw error }
    }
}
