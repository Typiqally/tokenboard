import Foundation
import XCTest
@testable import TokenboardCore

final class PricingInboxTests: XCTestCase {
    func testTemporaryAndOtherNamesAreIgnored() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        try candidateData(id: "candidate-temp").write(to: setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json.tmp"))
        try candidateData(id: "candidate-other").write(to: setup.inboxURL.appending(path: "other.json"))

        try await setup.inbox.start()

        let pending = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(applyCalls, 0)
    }

    func testExactFinalFilenameCreatesPendingPreviewWithoutApplying() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let candidateURL = setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        try candidateData(id: "candidate-valid").write(to: candidateURL)

        try await setup.inbox.start()

        let pending = await setup.inbox.pendingCandidate()
        XCTAssertEqual(pending?.catalog.catalogID, "candidate-valid")
        XCTAssertEqual(pending?.sourceURL, candidateURL)
        XCTAssertEqual(pending?.diff.modelsAdded, ["codex/gpt-test"])
        let applyCalls = await setup.ledger.applyCallCount()
        let snapshotCalls = await setup.ledger.snapshotCallCount()
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(snapshotCalls, 1)
    }

    func testWriteEventAfterStartDetectsExactCandidateWithoutPollingInProduction() async throws {
        let setup = try makeSetup()
        try await setup.inbox.start()
        try candidateData(id: "candidate-event").write(
            to: setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        )

        let detected = await eventually {
            await setup.inbox.pendingCandidate()?.catalog.catalogID == "candidate-event"
        }

        XCTAssertTrue(detected)
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertEqual(applyCalls, 0)
    }

    func testInvalidDataLeavesNoPendingCandidateAndNeverApplies() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        try Data("{not-json".utf8).write(
            to: setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        )

        try await setup.inbox.start()

        let pending = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        let snapshotCalls = await setup.ledger.snapshotCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testSymlinkCandidateIsRejected() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let target = setup.root.appending(path: "outside.json")
        try candidateData(id: "candidate-linked").write(to: target)
        try FileManager.default.createSymbolicLink(
            at: setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json"),
            withDestinationURL: target
        )

        try await setup.inbox.start()

        let pending = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(applyCalls, 0)
    }

    func testStartExportsLatestAppliedCatalogInsteadOfBundledFallback() async throws {
        let decoded = try PricingCatalogLoader().load(candidateData(id: "already-applied"))
        let latest = try PricingCatalogValidator().validate(decoded).canonicalJSON
        let setup = try makeSetup(latestApplied: latest)

        try await setup.inbox.start()

        let exported = try Data(contentsOf: setup.currentURL)
        let catalog = try PricingCatalogValidator().validate(PricingCatalogLoader().load(exported))
        XCTAssertEqual(catalog.catalogID, "already-applied")
    }

    func testApplyIsExplicitExportsAndArchivesCandidate() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let candidateURL = setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        try candidateData(id: "candidate-apply").write(to: candidateURL)
        try await setup.inbox.start()

        try await setup.inbox.applyPending()

        let pending = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(applyCalls, 1)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: setup.root.appending(path: "Pricing/Applied/candidate-apply.json").path
        ))
        let exported = try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(Data(contentsOf: setup.currentURL))
        )
        XCTAssertEqual(exported.catalogID, "candidate-apply")
    }

    func testRejectArchivesCandidateWithoutChangingActiveExport() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let candidateURL = setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        try candidateData(id: "candidate-reject").write(to: candidateURL)
        try await setup.inbox.start()
        let before = try Data(contentsOf: setup.currentURL)

        try await setup.inbox.rejectPending()

        let pending = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(applyCalls, 0)
        XCTAssertEqual(try Data(contentsOf: setup.currentURL), before)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: setup.root.appending(path: "Pricing/Rejected/candidate-reject.json").path
        ))
    }

    func testReplacementBeforeApplyNeverAppliesTheStalePreview() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let candidateURL = setup.inboxURL.appending(path: "tokenboard-pricing.candidate.json")
        try candidateData(id: "candidate-original").write(to: candidateURL)
        try await setup.inbox.start()
        try candidateData(id: "candidate-replacement").write(to: candidateURL, options: .atomic)

        do {
            try await setup.inbox.applyPending()
        } catch {}

        let appliedID = await setup.ledger.lastAppliedCatalogID()
        XCTAssertTrue(appliedID != "candidate-original")
    }

    private func makeSetup(latestApplied: Data? = nil) throws -> InboxSetup {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TokenboardPricingInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = PricingInboxTestLedger(latestApplied: latestApplied)
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData()
        )
        return InboxSetup(root: root, ledger: ledger, inbox: inbox)
    }

    private func bundledData() -> Data {
        Data(#"{"schemaVersion":1,"catalogID":"bundled-test","generatedAt":"2026-08-05T00:00:00Z","origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},"models":[]}"#.utf8)
    }

    private func candidateData(id: String) -> Data {
        Data(#"{"schemaVersion":1,"catalogID":"\#(id)","generatedAt":"2026-08-05T00:00:00Z","origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},"models":[{"provider":"codex","canonicalModelID":"gpt-test","aliases":[{"observedModelID":"gpt-test","effectiveFrom":"2026-01-01","effectiveTo":null}],"rates":[{"effectiveFrom":"2026-01-01","effectiveTo":null,"prices":{"input_uncached":"5.00","output":"30.00"},"provenanceURL":"https://openai.com/api/pricing/","verifiedAt":"2026-08-05"}]}]}"#.utf8)
    }
}

private final class InboxSetup: @unchecked Sendable {
    let root: URL
    let ledger: PricingInboxTestLedger
    let inbox: PricingInbox

    init(root: URL, ledger: PricingInboxTestLedger, inbox: PricingInbox) {
        self.root = root
        self.ledger = ledger
        self.inbox = inbox
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var inboxURL: URL { root.appending(path: "Pricing/Inbox", directoryHint: .isDirectory) }
    var currentURL: URL { root.appending(path: "Pricing/current-tokenboard-pricing.json") }
}

private actor PricingInboxTestLedger: LedgerStore {
    private var latestApplied: Data?
    private var applyCalls = 0
    private var snapshotCalls = 0
    private var appliedCatalogID: String?

    init(latestApplied: Data?) { self.latestApplied = latestApplied }

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
        snapshotCalls += 1
        return PricingSnapshot(catalogIDs: [], rates: [], aliases: [])
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
    }

    func applyCallCount() -> Int { applyCalls }
    func snapshotCallCount() -> Int { snapshotCalls }
    func lastAppliedCatalogID() -> String? { appliedCatalogID }
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
