import Foundation
import TokenboardCore

enum SourceGrantError: Error, Equatable {
    case accessDenied
}

struct ResolvedSourceBookmark: Equatable, Sendable {
    let url: URL
    let isStale: Bool
}

protocol SecurityScopedBookmarkAccessing: Sendable {
    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

private struct FoundationSecurityScopedBookmarkAccess: SecurityScopedBookmarkAccessing {
    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) throws -> Data {
        try url.bookmarkData(
            options: options,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return ResolvedSourceBookmark(url: url, isStale: isStale)
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

@MainActor
final class ActiveSourceGrant {
    let root: URL
    private let access: any SecurityScopedBookmarkAccessing
    private var isAccessing = false

    init(
        root: URL,
        access: any SecurityScopedBookmarkAccessing = FoundationSecurityScopedBookmarkAccess()
    ) throws {
        self.root = root
        self.access = access
        guard access.startAccessing(root) else {
            throw SourceGrantError.accessDenied
        }
        isAccessing = true
    }

    deinit {
        if isAccessing {
            access.stopAccessing(root)
        }
    }

    func close() {
        guard isAccessing else { return }
        access.stopAccessing(root)
        isAccessing = false
    }
}

@MainActor
final class SourceGrantStore {
    private let defaults: UserDefaults
    private let bookmarkAccess: any SecurityScopedBookmarkAccessing

    init(
        defaults: UserDefaults = .standard,
        bookmarkAccess: any SecurityScopedBookmarkAccessing = FoundationSecurityScopedBookmarkAccess()
    ) {
        self.defaults = defaults
        self.bookmarkAccess = bookmarkAccess
    }

    func grant(for provider: Provider) throws -> URL? {
        guard let data = defaults.data(forKey: bookmarkKey(for: provider)) else { return nil }
        let resolved = try bookmarkAccess.resolveBookmark(data, options: .withSecurityScope)
        let url = resolved.url.standardizedFileURL
        if resolved.isStale {
            let didAccess = bookmarkAccess.startAccessing(url)
            guard didAccess else { throw SourceGrantError.accessDenied }
            defer {
                bookmarkAccess.stopAccessing(url)
            }
            try save(url: url, for: provider)
        }
        return url
    }

    func save(url: URL, for provider: Provider) throws {
        let data = try bookmarkAccess.makeBookmark(
            for: url,
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        )
        defaults.set(data, forKey: bookmarkKey(for: provider))
    }

    func openGrant(for provider: Provider) throws -> ActiveSourceGrant? {
        guard let root = try grant(for: provider) else { return nil }
        return try ActiveSourceGrant(root: root, access: bookmarkAccess)
    }

    func revoke(_ provider: Provider) {
        defaults.removeObject(forKey: bookmarkKey(for: provider))
    }

    private func bookmarkKey(for provider: Provider) -> String {
        "sourceBookmark.\(provider.rawValue)"
    }
}
