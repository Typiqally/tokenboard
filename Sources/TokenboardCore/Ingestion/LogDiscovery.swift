import Foundation

public protocol LogDiscovering: Sendable {
    func jsonlFiles(under root: URL) throws -> [URL]
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
        for case let url as URL in enumerator {
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
}
