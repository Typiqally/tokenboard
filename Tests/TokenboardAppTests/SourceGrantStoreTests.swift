import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class SourceGrantStoreTests: XCTestCase {
    func testUsesExactBookmarkKeysAndSecurityScopedOptions() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let claude = URL(fileURLWithPath: "/tmp/claude")
        let codex = URL(fileURLWithPath: "/tmp/codex")

        try setup.store.save(url: claude, for: .claudeCode)
        try setup.store.save(url: codex, for: .codex)
        setup.access.resolved = ResolvedSourceBookmark(url: claude, isStale: false)
        _ = try setup.store.grant(for: .claudeCode)

        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([1]))
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.codex"), Data([1]))
        XCTAssertEqual(
            setup.access.creationOptions,
            [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
        )
        XCTAssertEqual(setup.access.resolutionOptions, [.withSecurityScope])
    }

    func testStaleBookmarkIsRecreatedWhileScopedAccessIsHeldAndBalancesOnError() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let root = URL(fileURLWithPath: "/tmp/claude")
        setup.defaults.set(Data([9]), forKey: "sourceBookmark.claude_code")
        setup.access.resolved = ResolvedSourceBookmark(url: root, isStale: true)
        setup.access.makeError = FakeBookmarkError.injected

        do {
            _ = try setup.store.grant(for: .claudeCode)
            XCTFail("expected bookmark recreation to fail")
        } catch is FakeBookmarkError {}

        XCTAssertEqual(setup.access.operations, [.resolve, .start, .make, .stop])
        XCTAssertEqual(setup.access.startCount, 1)
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testStaleBookmarkRecreationPersistsReplacementBeforeAccessStops() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let root = URL(fileURLWithPath: "/tmp/claude")
        setup.defaults.set(Data([9]), forKey: "sourceBookmark.claude_code")
        setup.access.resolved = ResolvedSourceBookmark(url: root, isStale: true)

        let resolved = try setup.store.grant(for: .claudeCode)

        XCTAssertEqual(resolved, root)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([1]))
        XCTAssertEqual(setup.access.operations, [.resolve, .start, .make, .stop])
    }

    func testActiveGrantCloseAndDeinitStopAccessExactlyOnce() throws {
        let access = FakeSecurityScopedBookmarkAccess()
        let root = URL(fileURLWithPath: "/tmp/claude")
        var grant: ActiveSourceGrant? = try ActiveSourceGrant(root: root, access: access)
        let weakGrant = WeakBox(grant)

        grant?.close()
        grant?.close()
        XCTAssertEqual(access.startCount, 1)
        XCTAssertEqual(access.stopCount, 1)

        grant = nil
        XCTAssertEqual(weakGrant.value == nil, true)
        XCTAssertEqual(access.stopCount, 1)

        var deinitGrant: ActiveSourceGrant? = try ActiveSourceGrant(root: root, access: access)
        let weakDeinitGrant = WeakBox(deinitGrant)
        deinitGrant = nil
        XCTAssertEqual(weakDeinitGrant.value == nil, true)
        XCTAssertEqual(access.startCount, 2)
        XCTAssertEqual(access.stopCount, 2)
    }

    func testOpenGrantUsesTheStoreAccessLifetime() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let root = URL(fileURLWithPath: "/tmp/claude")
        setup.defaults.set(Data([9]), forKey: "sourceBookmark.claude_code")
        setup.access.resolved = ResolvedSourceBookmark(url: root, isStale: false)

        guard let grant = try setup.store.openGrant(for: .claudeCode) else {
            XCTFail("expected a stored grant")
            return
        }
        XCTAssertEqual(setup.access.operations, [.resolve, .start])
        grant.close()
        XCTAssertEqual(setup.access.operations, [.resolve, .start, .stop])
    }

    func testPreparedReplacementKeepsStoredBookmarkUnchangedUntilCommit() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let oldBookmark = Data([9])
        let root = URL(fileURLWithPath: "/tmp/replacement")
        setup.defaults.set(oldBookmark, forKey: "sourceBookmark.claude_code")

        let prepared = try setup.store.prepareGrant(url: root, for: .claudeCode)

        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), oldBookmark)
        XCTAssertEqual(setup.access.operations, [.make, .start])
        prepared.close()
        XCTAssertEqual(setup.access.operations, [.make, .start, .stop])
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), oldBookmark)
    }

    func testPreparedGrantCanActivateBeforeBookmarkCommitForRestartRollback() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let oldBookmark = Data([9])
        let root = URL(fileURLWithPath: "/tmp/staged-restart")
        setup.defaults.set(oldBookmark, forKey: "sourceBookmark.claude_code")
        let prepared = try setup.store.prepareGrant(url: root, for: .claudeCode)

        let grant = setup.store.activate(prepared, for: .claudeCode)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), oldBookmark)

        setup.store.commitBookmark(prepared, for: .claudeCode)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([1]))
        grant.close()
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testFailedActiveGrantStartDoesNotStopAndRevokeDeletesOnlySelectedKey() throws {
        let setup = makeSetup()
        defer { setup.cleanup() }
        let root = URL(fileURLWithPath: "/tmp/claude")
        setup.access.startResult = false
        do {
            _ = try ActiveSourceGrant(root: root, access: setup.access)
            XCTFail("expected source access to be denied")
        } catch let error as SourceGrantError {
            XCTAssertEqual(error, .accessDenied)
        }
        XCTAssertEqual(setup.access.startCount, 1)
        XCTAssertEqual(setup.access.stopCount, 0)

        setup.defaults.set(Data([1]), forKey: "sourceBookmark.claude_code")
        setup.defaults.set(Data([2]), forKey: "sourceBookmark.codex")
        setup.store.revoke(.claudeCode)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), nil)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.codex"), Data([2]))
    }

    private func makeSetup() -> (
        store: SourceGrantStore,
        access: FakeSecurityScopedBookmarkAccess,
        defaults: UserDefaults,
        cleanup: () -> Void
    ) {
        let suiteName = "SourceGrantStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let access = FakeSecurityScopedBookmarkAccess()
        return (
            SourceGrantStore(defaults: defaults, bookmarkAccess: access),
            access,
            defaults,
            { defaults.removePersistentDomain(forName: suiteName) }
        )
    }
}

private enum FakeBookmarkError: Error {
    case injected
}

private final class FakeSecurityScopedBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    enum Operation: Equatable {
        case make
        case resolve
        case start
        case stop
    }

    var resolved = ResolvedSourceBookmark(
        url: URL(fileURLWithPath: "/tmp/source"),
        isStale: false
    )
    var startResult = true
    var makeError: Error?
    private(set) var operations: [Operation] = []
    private(set) var creationOptions: URL.BookmarkCreationOptions?
    private(set) var resolutionOptions: URL.BookmarkResolutionOptions?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func makeBookmark(
        for url: URL,
        options: URL.BookmarkCreationOptions
    ) throws -> Data {
        operations.append(.make)
        creationOptions = options
        if let makeError { throw makeError }
        return Data([1])
    }

    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark {
        operations.append(.resolve)
        resolutionOptions = options
        return resolved
    }

    func startAccessing(_ url: URL) -> Bool {
        operations.append(.start)
        startCount += 1
        return startResult
    }

    func stopAccessing(_ url: URL) {
        operations.append(.stop)
        stopCount += 1
    }
}

private final class WeakBox<Value: AnyObject> {
    weak var value: Value?

    init(_ value: Value?) {
        self.value = value
    }
}
