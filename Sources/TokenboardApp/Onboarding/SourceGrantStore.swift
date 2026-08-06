import Foundation
import TokenboardCore

enum SourceGrantError: Error {
    case accessDenied
}

@MainActor
final class ActiveSourceGrant {
    let root: URL
    private var isAccessing = false

    init(root: URL) throws {
        self.root = root
        guard root.startAccessingSecurityScopedResource() else {
            throw SourceGrantError.accessDenied
        }
        isAccessing = true
    }

    deinit {
        if isAccessing {
            root.stopAccessingSecurityScopedResource()
        }
    }

    func close() {
        guard isAccessing else { return }
        root.stopAccessingSecurityScopedResource()
        isAccessing = false
    }
}

@MainActor
final class SourceGrantStore {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func grant(for provider: Provider) throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey(for: provider)) else { return nil }
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ).standardizedFileURL
        if isStale {
            let didAccess = url.startAccessingSecurityScopedResource()
            guard didAccess else { throw SourceGrantError.accessDenied }
            defer {
                url.stopAccessingSecurityScopedResource()
            }
            try save(url: url, for: provider)
        }
        return url
    }

    func save(url: URL, for provider: Provider) throws {
        let data = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(data, forKey: bookmarkKey(for: provider))
    }

    func openGrant(for provider: Provider) throws -> ActiveSourceGrant? {
        guard let root = try grant(for: provider) else { return nil }
        return try ActiveSourceGrant(root: root)
    }

    func revoke(_ provider: Provider) {
        defaults.removeObject(forKey: bookmarkKey(for: provider))
    }

    private func bookmarkKey(for provider: Provider) -> String {
        "sourceBookmark.\(provider.rawValue)"
    }
}
