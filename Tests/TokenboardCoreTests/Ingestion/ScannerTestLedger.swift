import Foundation
@testable import TokenboardCore

enum ScannerTestLedgerError: Error, Equatable {
    case injectedCommitFailure
}

struct CapturedScannerCommit: Equatable, Sendable {
    let usage: [NormalizedUsage]
    let skipped: [SkippedRecord]
    let checkpoint: SourceCheckpoint
}

actor ScannerTestLedger: LedgerStore {
    private let hasher = PrivacyHasher(salt: Data(repeating: 0xA7, count: 32))
    private var remainingCommitFailures: Int
    private var storedCheckpoint: SourceCheckpoint?
    private var attempts: [CapturedScannerCommit] = []
    private var successfulCommits: [CapturedScannerCommit] = []

    init(failFirstCommit: Bool = false) {
        remainingCommitFailures = failFirstCommit ? 1 : 0
    }

    func migrate() {}

    func commit(
        _ usage: [NormalizedUsage],
        skipped: [SkippedRecord],
        checkpoint: SourceCheckpoint,
        calendar: Calendar
    ) throws {
        let captured = CapturedScannerCommit(usage: usage, skipped: skipped, checkpoint: checkpoint)
        attempts.append(captured)
        if remainingCommitFailures > 0 {
            remainingCommitFailures -= 1
            throw ScannerTestLedgerError.injectedCommitFailure
        }
        successfulCommits.append(captured)
        storedCheckpoint = checkpoint
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

    func seed(checkpoint: SourceCheckpoint) {
        storedCheckpoint = checkpoint
    }

    func capturedAttempts() -> [CapturedScannerCommit] { attempts }

    func capturedSuccessfulCommits() -> [CapturedScannerCommit] { successfulCommits }

    func capturedCheckpoint() -> SourceCheckpoint? { storedCheckpoint }
}
