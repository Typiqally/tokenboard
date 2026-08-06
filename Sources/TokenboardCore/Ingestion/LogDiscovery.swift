import Foundation

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
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "jsonl" else {
                continue
            }
            files.append(url.standardizedFileURL)
        }
        return files.sorted { $0.path < $1.path }
    }

    public func enumerateJSONLFiles(
        under root: URL,
        maximumChunkSize: Int,
        consume: @escaping @Sendable ([URL]) async throws -> Void
    ) async throws {
        precondition(maximumChunkSize > 0)
        let resourceKeys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return
        }

        var chunk: [URL] = []
        chunk.reserveCapacity(maximumChunkSize)
        while let url = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  url.pathExtension.lowercased() == "jsonl" else {
                continue
            }
            chunk.append(url.standardizedFileURL)
            if chunk.count == maximumChunkSize {
                try await consume(chunk.sorted { $0.path < $1.path })
                chunk.removeAll(keepingCapacity: true)
            }
        }
        try Task.checkCancellation()
        if !chunk.isEmpty {
            try await consume(chunk.sorted { $0.path < $1.path })
        }
    }
}
