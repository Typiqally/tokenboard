import Foundation
@testable import TokenboardCore

enum ScannerTestLedgerError: Error, Equatable {
    case injectedCommitFailure
    case unsupportedPricing
}

struct CapturedScannerCommit: Equatable, Sendable {
    let usage: [NormalizedUsage]
    let agentActivity: [AgentActivityObservation]
    let skipped: [SkippedRecord]
    let checkpoint: SourceCheckpoint
}

struct CapturedAgentActivityBackfill: Equatable, Sendable {
    let rows: [AgentActivityRow]
    let fingerprint: String
    let expectedOffset: Int64
}

actor ScannerTestLedger: LedgerStore {
    private let hasher = PrivacyHasher(salt: Data(repeating: 0xA7, count: 32))
    private var remainingCommitFailures: Int
    private let cancelAfterCommit: Bool
    private var storedCheckpoint: SourceCheckpoint?
    private var storedAgentActivityBackfillOffset: Int64 = 0
    private var attempts: [CapturedScannerCommit] = []
    private var successfulCommits: [CapturedScannerCommit] = []
    private var agentActivityBackfills: [CapturedAgentActivityBackfill] = []

    init(failFirstCommit: Bool = false, cancelAfterCommit: Bool = false) {
        remainingCommitFailures = failFirstCommit ? 1 : 0
        self.cancelAfterCommit = cancelAfterCommit
    }

    func migrate() {}

    func commit(
        _ usage: [NormalizedUsage],
        agentActivity: [AgentActivityObservation],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) throws {
        let captured = CapturedScannerCommit(
            usage: usage,
            agentActivity: agentActivity,
            skipped: skipped,
            checkpoint: checkpoint
        )
        attempts.append(captured)
        if remainingCommitFailures > 0 {
            remainingCommitFailures -= 1
            throw ScannerTestLedgerError.injectedCommitFailure
        }
        successfulCommits.append(captured)
        storedCheckpoint = checkpoint
        if cancelAfterCommit {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func backfillActivitySlices(
        _ observations: [ActivityObservation],
        calendar: Calendar
    ) {}

    func agentActivityBackfillOffset(for fingerprint: String) -> Int64? {
        storedCheckpoint?.fingerprint == fingerprint ? storedAgentActivityBackfillOffset : nil
    }

    func commitAgentActivityBackfill(
        _ rows: [AgentActivityRow],
        fingerprint: String,
        expectedOffset: Int64
    ) throws {
        guard storedCheckpoint?.fingerprint == fingerprint,
              storedAgentActivityBackfillOffset == expectedOffset,
              expectedOffset > 0 else {
            throw LedgerError.staleAgentActivityBackfill
        }
        agentActivityBackfills.append(CapturedAgentActivityBackfill(
            rows: rows,
            fingerprint: fingerprint,
            expectedOffset: expectedOffset
        ))
        storedAgentActivityBackfillOffset = 0
    }

    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }

    func checkpoint(for fingerprint: String) -> SourceCheckpoint? {
        storedCheckpoint?.fingerprint == fingerprint ? storedCheckpoint : nil
    }

    func sourceFingerprint(provider: Provider, stableID: String) -> String {
        hasher.fingerprint(provider: provider, stableID: stableID)
    }

    func recordIdentityHash(_ value: String) -> String {
        hasher.recordHash(value)
    }

    func pricingSnapshot() throws -> PricingSnapshot {
        throw ScannerTestLedgerError.unsupportedPricing
    }

    func latestAppliedPricingCatalogJSON() throws -> Data? {
        throw ScannerTestLedgerError.unsupportedPricing
    }

    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        throw ScannerTestLedgerError.unsupportedPricing
    }

    func seed(checkpoint: SourceCheckpoint, agentActivityBackfillOffset: Int64 = 0) {
        storedCheckpoint = checkpoint
        storedAgentActivityBackfillOffset = agentActivityBackfillOffset
    }

    func capturedAgentActivityBackfills() -> [CapturedAgentActivityBackfill] { agentActivityBackfills }

    func capturedAttempts() -> [CapturedScannerCommit] { attempts }

    func capturedSuccessfulCommits() -> [CapturedScannerCommit] { successfulCommits }

    func capturedCheckpoint() -> SourceCheckpoint? { storedCheckpoint }
}
