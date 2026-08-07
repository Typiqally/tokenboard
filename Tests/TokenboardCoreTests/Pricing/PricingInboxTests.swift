import Foundation
import XCTest
@testable import TokenboardCore

final class PricingInboxTests: XCTestCase {
    func testExistingCurrentCatalogAutomaticallyAppliesOnStart() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(
            at: setup.currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try catalogData(id: "authoritative-current").write(to: setup.currentURL)

        try await setup.catalogStore.start()

        let appliedID = await setup.ledger.lastAppliedCatalogID()
        let status = await setup.catalogStore.status()
        XCTAssertEqual(appliedID, "authoritative-current")
        XCTAssertEqual(status, .current(catalogID: "authoritative-current"))
    }

    func testReplacingCurrentCatalogAutomaticallyAppliesWhileRunning() async throws {
        let setup = try makeSetup()
        try await setup.catalogStore.start()

        try catalogData(id: "authoritative-update").write(
            to: setup.currentURL,
            options: .atomic
        )

        let applied = await eventually {
            await setup.ledger.lastAppliedCatalogID() == "authoritative-update"
        }
        let status = await setup.catalogStore.status()
        XCTAssertTrue(applied)
        XCTAssertEqual(status, .current(catalogID: "authoritative-update"))
    }

    func testInvalidReplacementKeepsLastValidCatalogActive() async throws {
        let setup = try makeSetup()
        try await setup.catalogStore.start()
        try catalogData(id: "valid-update").write(to: setup.currentURL, options: .atomic)
        let applied = await eventually {
            await setup.ledger.lastAppliedCatalogID() == "valid-update"
        }
        XCTAssertTrue(applied)

        try Data("{not-json".utf8).write(to: setup.currentURL, options: .atomic)

        let invalidPublished = await eventually {
            await setup.catalogStore.status() == .invalid(.invalidCatalog)
        }
        let appliedID = await setup.ledger.lastAppliedCatalogID()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertTrue(invalidPublished)
        XCTAssertEqual(appliedID, "valid-update")
        XCTAssertEqual(applyCalls, 1)
    }

    func testUnsafeCurrentFileDoesNotReplaceLastValidCatalog() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(
            at: setup.currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let outside = setup.root.appending(path: "outside.json")
        try catalogData(id: "outside").write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: setup.currentURL,
            withDestinationURL: outside
        )

        try await setup.catalogStore.start()

        let status = await setup.catalogStore.status()
        let appliedID = await setup.ledger.lastAppliedCatalogID()
        XCTAssertEqual(status, .invalid(.unreadableCatalog))
        XCTAssertNil(appliedID)
    }

    func testMissingCurrentFileExportsLatestAppliedCatalog() async throws {
        let latest = try validatedCatalog(id: "latest-applied").canonicalJSON
        let setup = try makeSetup(
            latestApplied: latest,
            storedCatalogIDs: ["latest-applied"]
        )

        try await setup.catalogStore.start()

        let exported = try PricingCatalogLoader().load(Data(contentsOf: setup.currentURL))
        let status = await setup.catalogStore.status()
        XCTAssertEqual(exported.catalogID, "latest-applied")
        XCTAssertEqual(status, .current(catalogID: "latest-applied"))
    }

    func testStartupCompactsLegacyAccumulatedCatalogsOnlyWhenNeeded() async throws {
        let latest = try validatedCatalog(id: "authoritative").canonicalJSON
        let setup = try makeSetup(
            latestApplied: latest,
            storedCatalogIDs: ["older", "authoritative"]
        )
        try FileManager.default.createDirectory(
            at: setup.currentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try latest.write(to: setup.currentURL)

        try await setup.catalogStore.start()

        let applyCalls = await setup.ledger.applyCallCount()
        let status = await setup.catalogStore.status()
        XCTAssertEqual(applyCalls, 1)
        XCTAssertEqual(status, .current(catalogID: "authoritative"))
    }

    func testLegacyReviewDirectoriesAreNeverCreated() async throws {
        let setup = try makeSetup()

        try await setup.catalogStore.start()

        for name in ["Inbox", "Applied", "Rejected"] {
            XCTAssertFalse(FileManager.default.fileExists(
                atPath: setup.root.appending(path: "Pricing/\(name)").path
            ))
        }
    }

    private func makeSetup(
        latestApplied: Data? = nil,
        storedCatalogIDs: [String]? = nil
    ) throws -> CatalogSetup {
        let root = FileManager.default.temporaryDirectory.appending(
            path: "TokenboardPricingCatalogTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaultCatalogID = try latestApplied.map {
            try PricingCatalogLoader().load($0).catalogID
        } ?? "bundled-test"
        let ledger = PricingCatalogTestLedger(
            latestApplied: latestApplied,
            storedCatalogIDs: storedCatalogIDs ?? [defaultCatalogID]
        )
        let store = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: catalogData(id: "bundled-test")
        )
        return CatalogSetup(root: root, ledger: ledger, catalogStore: store)
    }

    private func validatedCatalog(id: String) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalogLoader().load(catalogData(id: id)))
    }

    private func catalogData(id: String) -> Data {
        Data(#"{"schemaVersion":1,"catalogID":"\#(id)","generatedAt":"2026-08-05T00:00:00Z","origin":{"kind":"web_research","url":"https://prices.example/catalog"},"models":[{"provider":"codex","canonicalModelID":"gpt-test","aliases":[{"observedModelID":"gpt-test","effectiveFrom":"2026-01-01","effectiveTo":null}],"rates":[{"effectiveFrom":"2026-01-01","effectiveTo":null,"prices":{"input_uncached":"5.00","output":"30.00"},"provenanceURL":"https://prices.example/model","verifiedAt":"2026-08-05"}]}]}"#.utf8)
    }

}

private final class CatalogSetup: @unchecked Sendable {
    let root: URL
    let ledger: PricingCatalogTestLedger
    let catalogStore: PricingInbox

    init(root: URL, ledger: PricingCatalogTestLedger, catalogStore: PricingInbox) {
        self.root = root
        self.ledger = ledger
        self.catalogStore = catalogStore
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var currentURL: URL {
        root.appending(path: "Pricing/\(PricingInbox.currentCatalogFilename)")
    }
}

private actor PricingCatalogTestLedger: LedgerStore {
    private var latestApplied: Data?
    private var appliedCatalogID: String?
    private var applyCalls = 0
    private var storedCatalogIDs: [String]

    init(latestApplied: Data?, storedCatalogIDs: [String]) {
        self.latestApplied = latestApplied
        self.storedCatalogIDs = storedCatalogIDs
    }

    func migrate() {}
    func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) {}
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func checkpoint(for fingerprint: String) -> SourceCheckpoint? { nil }
    func sourceFingerprint(provider: Provider, stableID: String) -> String { "unused" }
    func recordIdentityHash(_ value: String) -> String { "unused" }
    func pricingSnapshot() -> PricingSnapshot {
        PricingSnapshot(catalogIDs: storedCatalogIDs, rates: [], aliases: [])
    }
    func latestAppliedPricingCatalogJSON() -> Data? { latestApplied }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {
        applyCalls += 1
        latestApplied = canonicalJSON
        appliedCatalogID = catalog.catalogID
        storedCatalogIDs = [catalog.catalogID]
    }

    func lastAppliedCatalogID() -> String? { appliedCatalogID }
    func applyCallCount() -> Int { applyCalls }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
