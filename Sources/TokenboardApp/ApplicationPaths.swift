import Foundation

struct ApplicationPaths {
    let root: URL

    var ledger: URL { root.appending(path: "ledger.sqlite") }
    var backups: URL { root.appending(path: "Backups", directoryHint: .isDirectory) }
    var pricing: URL { root.appending(path: "Pricing", directoryHint: .isDirectory) }

    static func resolve(fileManager: FileManager = .default) throws -> ApplicationPaths {
        let root = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return ApplicationPaths(root: root.standardizedFileURL)
    }
}
