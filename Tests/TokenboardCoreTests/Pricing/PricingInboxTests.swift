import Foundation
import Darwin
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
        XCTAssertEqual(snapshotCalls, 0)
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
        let status = await setup.inbox.status()
        let applyCalls = await setup.ledger.applyCallCount()
        let snapshotCalls = await setup.ledger.snapshotCallCount()
        XCTAssertNil(pending)
        XCTAssertEqual(status, .invalid(.invalidCatalog))
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

    func testReviewedIdentityRejectsReplacementAndRequiresFreshApproval() async throws {
        let setup = try makeSetup()
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        let candidateURL = setup.inboxURL.appending(path: PricingInbox.candidateFilename)
        try candidateData(id: "approved-original").write(to: candidateURL)
        try await setup.inbox.start()
        let detected = await setup.inbox.pendingCandidate()
        let approved = try XCTUnwrap(detected)
        try candidateData(id: "unapproved-replacement").write(to: candidateURL, options: .atomic)

        await assertInboxError(.candidateChanged) {
            _ = try await setup.inbox.applyPending(matching: approved.identity)
        }
        let refreshed = await eventually {
            await setup.inbox.pendingCandidate()?.catalog.catalogID == "unapproved-replacement"
        }

        XCTAssertTrue(refreshed)
        let replacement = await setup.inbox.pendingCandidate()
        let applyCalls = await setup.ledger.applyCallCount()
        XCTAssertNotEqual(replacement?.identity, approved.identity)
        XCTAssertEqual(applyCalls, 0)
    }

    func testBundledFallbackHistoryIsNotReportedAsNewButTrueAdditionIs() async throws {
        let bundled = try Data(contentsOf: TestRepository.root.appending(path: "Resources/tokenboard-pricing.json"))
        let decoded = try PricingCatalogLoader().load(bundled)
        let added = CatalogModel(
            provider: .codex,
            canonicalModelID: "gpt-added",
            aliases: [CatalogAlias(observedModelID: "gpt-added", effectiveFrom: "2026-08-06", effectiveTo: nil)],
            rates: [CatalogRate(
                effectiveFrom: "2026-08-06",
                effectiveTo: nil,
                prices: ["input_uncached": DecimalString(decimal: 7), "output": DecimalString(decimal: 35)],
                provenanceURL: "https://openai.com/api/pricing/",
                verifiedAt: "2026-08-06"
            )]
        )
        let candidate = PricingCatalog(
            schemaVersion: decoded.schemaVersion,
            catalogID: "bundled-plus-one",
            generatedAt: "2026-08-06T00:00:00Z",
            origin: decoded.origin,
            models: decoded.models + [added]
        )
        let candidateData = try JSONEncoder().encode(candidate)
        let setup = try makeSetup(bundledCatalogData: bundled)
        try FileManager.default.createDirectory(at: setup.inboxURL, withIntermediateDirectories: true)
        try candidateData.write(to: setup.inboxURL.appending(path: PricingInbox.candidateFilename))

        try await setup.inbox.start()

        let diff = await setup.inbox.pendingCandidate()?.diff
        XCTAssertEqual(diff?.modelsAdded, ["codex/gpt-added"])
        XCTAssertEqual(diff?.aliasesAdded, 1)
        XCTAssertEqual(diff?.ratesAdded, 2)
        let snapshotCalls = await setup.ledger.snapshotCallCountValue()
        XCTAssertEqual(snapshotCalls, 0)
    }

    func testConcurrentRejectIsRejectedWhileApplySuspends() async throws {
        let root = try makeRoot(label: "ConcurrentReject")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "concurrent-reject").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = SuspendingPricingLedger()
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())
        try await inbox.start()
        let applyTask = Task { try await inbox.applyPending() }
        await ledger.waitUntilApplyStarted()

        await assertInboxError(.resolutionInProgress) {
            try await inbox.rejectPending()
        }
        await ledger.resumeApply()
        try await applyTask.value
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(applyCalls, 1)
    }

    func testQuiesceWaitsThroughApplyFinalizationAndBlocksNewResolution() async throws {
        let root = try makeRoot(label: "QuiesceApply")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "quiesce-apply").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = SuspendingPricingLedger()
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData()
        )
        try await inbox.start()
        let apply = Task { try await inbox.applyPending() }
        await ledger.waitUntilApplyStarted()
        let completion = QuiescenceCompletion()
        let quiesce = Task {
            await inbox.quiesce()
            await completion.markCompleted()
        }

        let blocked = await eventually {
            do {
                try await inbox.rejectPending()
                return false
            } catch let error as PricingInboxError {
                return error == .quiescing
            } catch {
                return false
            }
        }
        XCTAssertTrue(blocked)
        let completedWhileSuspended = await completion.isCompleted()
        XCTAssertFalse(completedWhileSuspended)
        await assertInboxError(.resolutionInProgress) { try await inbox.stop() }

        await ledger.resumeApply()
        try await apply.value
        await quiesce.value
        let completedAfterApply = await completion.isCompleted()
        XCTAssertTrue(completedAfterApply)
        try await inbox.stop()
    }

    func testConcurrentSecondApplyIsRejectedWhileFirstApplySuspends() async throws {
        let root = try makeRoot(label: "ConcurrentApply")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "concurrent-apply").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = SuspendingPricingLedger()
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())
        try await inbox.start()
        let firstApply = Task { try await inbox.applyPending() }
        await ledger.waitUntilApplyStarted()

        await assertInboxError(.resolutionInProgress) {
            try await inbox.applyPending()
        }
        await ledger.resumeApply()
        try await firstApply.value
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(applyCalls, 1)
    }

    func testPreCommitFailureRestoresValidatedCandidateForRetry() async throws {
        let root = try makeRoot(label: "PreCommit")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "precommit").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = FailOncePricingLedger()
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())
        try await inbox.start()

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let restored = await inbox.pendingCandidate()
        XCTAssertEqual(restored?.catalog.catalogID, "precommit")
        try await inbox.applyPending()
        let cleared = await inbox.pendingCandidate()
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(cleared)
        XCTAssertEqual(applyCalls, 2)
    }

    func testIsolationSyncFailureRestoresPendingCandidateForSameRunRetry() async throws {
        let root = try makeRoot(label: "IsolationSync")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        try candidateData(id: "isolation-sync").write(to: candidateURL)
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 1)

        do {
            try await inbox.applyPending()
            XCTFail("expected post-isolation sync failure")
        } catch let error as PricingInboxMutationError {
            XCTAssertTrue(error.mutationCompleted)
            guard case let .moveInbox(from, to) = error.mutation else {
                return XCTFail("expected completed inbox move")
            }
            XCTAssertEqual(from, PricingInbox.candidateFilename)
            XCTAssertTrue(to.hasPrefix(PricingInbox.processingFilenamePrefix))
        } catch {
            XCTFail("expected structured mutation error, got \(error)")
        }

        let restored = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(restored?.catalog.catalogID, "isolation-sync")
        XCTAssertEqual(firstApplyCalls, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertEqual(try processingNames(in: root), [])

        try await inbox.applyPending()

        let cleared = await inbox.pendingCandidate()
        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(cleared)
        XCTAssertEqual(finalApplyCalls, 1)
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testRestorationSyncFailureRevalidatesCandidateForSameRunRetry() async throws {
        let root = try makeRoot(label: "RestorationSync")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        try candidateData(id: "restoration-sync").write(to: candidateURL)
        let ledger = FailOncePricingLedger()
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 2)

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let restored = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(restored?.catalog.catalogID, "restoration-sync")
        XCTAssertEqual(firstApplyCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertEqual(try processingNames(in: root), [])

        try await inbox.applyPending()

        let cleared = await inbox.pendingCandidate()
        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(cleared)
        XCTAssertEqual(finalApplyCalls, 2)
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testPreCommitProcessingCandidateIsNotOverwrittenByAReplacementEvent() async throws {
        let root = try makeRoot(label: "PreCommitReplacement")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "approved-original").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = SuspendingFailPricingLedger()
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())
        try await inbox.start()
        let applyTask = Task { try await inbox.applyPending() }
        await ledger.waitUntilApplyStarted()
        try candidateData(id: "new-replacement").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        await ledger.resumeApply()
        _ = try? await applyTask.value
        try? await Task.sleep(for: .milliseconds(100))

        let pending = await inbox.pendingCandidate()
        XCTAssertEqual(pending?.catalog.catalogID, "approved-original")
        try await inbox.rejectPending()
        let detectedReplacement = await eventually {
            await inbox.pendingCandidate()?.catalog.catalogID == "new-replacement"
        }
        XCTAssertTrue(detectedReplacement)
    }

    func testPostCommitExportFailureRemainsFinalizationOnlyAndRetryDoesNotReapply() async throws {
        let root = try makeRoot(label: "PostCommitExport")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "postcommit-export").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        fileSystem.failNext(.replaceCanonical(.pricing, "current-tokenboard-pricing.json"))

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let pending = await inbox.pendingCandidate()
        XCTAssertNil(pending)
        await assertInboxError(.candidateAlreadyApplied) { try await inbox.rejectPending() }
        try await inbox.applyPending()
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(applyCalls, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "Pricing/Applied/postcommit-export.json").path
        ))
    }

    func testReviewedApplyReportsCommittedFinalizationPendingAndRetryFinalizesOnly() async throws {
        let root = try makeRoot(label: "ReviewedPostCommit")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "reviewed-postcommit").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        let detected = await inbox.pendingCandidate()
        let reviewed = try XCTUnwrap(detected)
        fileSystem.failNext(.replaceCanonical(.pricing, PricingInbox.currentCatalogFilename))

        let first = try await inbox.applyPending(matching: reviewed.identity)

        XCTAssertEqual(first, .committedFinalizationPending)
        let pendingFinalization = await inbox.status()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(pendingFinalization, .appliedFinalizing(reviewed.identity))
        XCTAssertEqual(firstApplyCalls, 1)

        let staleCatalog = try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(candidateData(id: "stale-finalization"))
        )
        let staleIdentity = PricingCandidateIdentity(
            canonicalJSON: staleCatalog.canonicalJSON
        )
        await assertInboxError(.candidateChanged) {
            _ = try await inbox.retryFinalization(matching: staleIdentity)
        }
        let statusAfterStaleRetry = await inbox.status()
        let callsAfterStaleRetry = await ledger.applyCallCountValue()
        XCTAssertEqual(statusAfterStaleRetry, .appliedFinalizing(reviewed.identity))
        XCTAssertEqual(callsAfterStaleRetry, 1)

        let retry = try await inbox.retryFinalization(matching: reviewed.identity)
        XCTAssertEqual(retry, .applied)
        let finalStatus = await inbox.status()
        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(finalStatus, .empty)
        XCTAssertEqual(finalApplyCalls, 1)
    }

    func testPostCommitArchiveFailureRetriesFinalizationWithoutReapplying() async throws {
        let root = try makeRoot(label: "PostCommitArchive")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "postcommit-archive").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        fileSystem.failNext(.installCanonical(.applied, "postcommit-archive.json"))

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        await assertInboxError(.candidateAlreadyApplied) { try await inbox.rejectPending() }
        try await inbox.applyPending()
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(applyCalls, 1)
    }

    func testQuiescedStopClosesCommittedFinalizationResidueWithoutReapplying() async throws {
        let root = try makeRoot(label: "QuiescedCommittedFinalization")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "quiesced-committed").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        fileSystem.failNext(.installCanonical(.applied, "quiesced-committed.json"))
        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        await inbox.quiesce()
        try await inbox.stop()

        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(applyCalls, 1)
        XCTAssertEqual(fileSystem.closeCallCount(), 1)
    }

    func testPostCommitExportSyncFailureRemainsFinalizationOnlyUntilSameRunRetry() async throws {
        let root = try makeRoot(label: "PostCommitExportSync")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "postcommit-export-sync").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 2)

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let pending = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(pending)
        XCTAssertEqual(firstApplyCalls, 1)
        await assertInboxError(.candidateAlreadyApplied) { try await inbox.rejectPending() }
        XCTAssertEqual(
            try PricingCatalogLoader().load(
                Data(contentsOf: root.appending(path: "Pricing/current-tokenboard-pricing.json"))
            ).catalogID,
            "postcommit-export-sync"
        )
        XCTAssertEqual(try processingNames(in: root).count, 1)

        try await inbox.applyPending()

        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(finalApplyCalls, 1)
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testPostCommitArchiveSyncFailureRetriesCleanupWithoutReapplying() async throws {
        let root = try makeRoot(label: "PostCommitArchiveSync")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "postcommit-archive-sync").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 3)

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let pending = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(pending)
        XCTAssertEqual(firstApplyCalls, 1)
        await assertInboxError(.candidateAlreadyApplied) { try await inbox.rejectPending() }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "Pricing/Applied/postcommit-archive-sync.json").path
        ))
        XCTAssertEqual(try processingNames(in: root).count, 1)

        try await inbox.applyPending()

        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(finalApplyCalls, 1)
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testRejectedArchiveSyncFailureRestoresPendingCandidateForRetry() async throws {
        let root = try makeRoot(label: "RejectedArchiveSync")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        try candidateData(id: "rejected-archive-sync").write(to: candidateURL)
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 2)

        await XCTAssertThrowsErrorAsync { try await inbox.rejectPending() }

        let restored = await inbox.pendingCandidate()
        XCTAssertEqual(restored?.catalog.catalogID, "rejected-archive-sync")
        XCTAssertTrue(FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "Pricing/Rejected/rejected-archive-sync.json").path
        ))
        XCTAssertEqual(try processingNames(in: root), [])

        try await inbox.rejectPending()

        let cleared = await inbox.pendingCandidate()
        let applyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(cleared)
        XCTAssertEqual(applyCalls, 0)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testRejectedCleanupSyncFailurePreservesFinalizationOnlyRetry() async throws {
        let root = try makeRoot(label: "RejectedCleanupSync")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        try candidateData(id: "rejected-cleanup-sync").write(to: candidateURL)
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 3)

        await XCTAssertThrowsErrorAsync { try await inbox.rejectPending() }

        let pending = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(pending)
        XCTAssertEqual(firstApplyCalls, 0)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: candidateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appending(path: "Pricing/Rejected/rejected-cleanup-sync.json").path
        ))
        XCTAssertEqual(try processingNames(in: root), [])
        XCTAssertEqual(sync.attemptCount(), 3)
        await assertInboxError(.resolutionInProgress) { try await inbox.applyPending() }

        let finalizingStatus = await inbox.status()
        guard case let .rejectedFinalizing(identity) = finalizingStatus else {
            return XCTFail("expected rejected finalization state")
        }
        let staleCatalog = try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(candidateData(id: "stale-rejection-finalization"))
        )
        await assertInboxError(.candidateChanged) {
            _ = try await inbox.retryFinalization(matching: PricingCandidateIdentity(
                canonicalJSON: staleCatalog.canonicalJSON
            ))
        }
        let callsAfterStaleRetry = await ledger.applyCallCountValue()
        XCTAssertEqual(callsAfterStaleRetry, 0)

        let retry = try await inbox.retryFinalization(matching: identity)

        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(retry, .rejected)
        XCTAssertEqual(finalApplyCalls, 0)
        XCTAssertEqual(sync.attemptCount(), 4)
        XCTAssertEqual(try processingNames(in: root), [])
        await assertInboxError(.noPendingCandidate) { try await inbox.rejectPending() }
    }

    func testPostCommitCleanupSyncFailureRetriesWithoutReapplyingOrOrphaning() async throws {
        let root = try makeRoot(label: "PostCommitCleanupSync")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "postcommit-cleanup-sync").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let sync = DirectorySyncFailureInjector()
        let fileSystem = POSIXPricingInboxFileSystem(directorySync: { sync.call($0) })
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        sync.fail(atAttempt: 4)

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        let pending = await inbox.pendingCandidate()
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertNil(pending)
        XCTAssertEqual(firstApplyCalls, 1)
        XCTAssertEqual(try processingNames(in: root), [])

        try await inbox.applyPending()

        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(finalApplyCalls, 1)
        XCTAssertEqual(try processingNames(in: root), [])
    }

    func testRelaunchFinalizesCommittedProcessingResidueWithoutPresentingItForRejection() async throws {
        let root = try makeRoot(label: "Relaunch")
        defer { try? FileManager.default.removeItem(at: root) }
        let validated = try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(candidateData(id: "committed-residue"))
        )
        let processingName = ".candidate-processing-relaunch.json"
        try validated.canonicalJSON.write(to: root.appending(path: "Pricing/Inbox/\(processingName)"))
        let ledger = PricingInboxTestLedger(latestApplied: validated.canonicalJSON)
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())

        try await inbox.start()

        let pending = await inbox.pendingCandidate()
        XCTAssertNil(pending)
        XCTAssertTrue(!FileManager.default.fileExists(atPath: root.appending(path: "Pricing/Inbox/\(processingName)").path))
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "Pricing/Applied/committed-residue.json")),
            validated.canonicalJSON
        )
    }

    func testRetainedDirectoriesDefeatParentPathSwap() async throws {
        let root = try makeRoot(label: "ParentSwap")
        defer { try? FileManager.default.removeItem(at: root) }
        let inbox = PricingInbox(
            ledger: PricingInboxTestLedger(latestApplied: nil),
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData()
        )
        try await inbox.start()
        let retainedPricing = root.appending(path: "Pricing-retained")
        try FileManager.default.moveItem(at: root.appending(path: "Pricing"), to: retainedPricing)
        let attacker = root.appending(path: "Attacker")
        try FileManager.default.createDirectory(at: attacker.appending(path: "Inbox"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "Pricing"), withDestinationURL: attacker)
        try candidateData(id: "attacker").write(to: attacker.appending(path: "Inbox/\(PricingInbox.candidateFilename)"))
        try candidateData(id: "retained").write(to: retainedPricing.appending(path: "Inbox/\(PricingInbox.candidateFilename)"))

        let detected = await eventually { await inbox.pendingCandidate()?.catalog.catalogID == "retained" }

        XCTAssertTrue(detected)
    }

    func testArchiveUsesFreshCanonicalInodeUnaffectedByExternalWriter() async throws {
        let root = try makeRoot(label: "FreshInode")
        defer { try? FileManager.default.removeItem(at: root) }
        let candidateURL = root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        try candidateData(id: "fresh-inode").write(to: candidateURL)
        let writer = open(candidateURL.path, O_WRONLY | O_CLOEXEC)
        XCTAssertTrue(writer >= 0)
        defer { if writer >= 0 { close(writer) } }
        let inbox = PricingInbox(
            ledger: PricingInboxTestLedger(latestApplied: nil),
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData()
        )
        try await inbox.start()
        let canonical = await inbox.pendingCandidate()?.canonicalJSON

        try await inbox.applyPending()
        _ = lseek(writer, 0, SEEK_SET)
        var mutation = [UInt8]("X".utf8)
        _ = write(writer, &mutation, mutation.count)

        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "Pricing/Applied/fresh-inode.json")),
            canonical
        )
    }

    func testArchiveAndExportSymlinksFailClosedWithoutTouchingTargets() async throws {
        let root = try makeRoot(label: "NoFollow")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "nofollow").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let ledger = PricingInboxTestLedger(latestApplied: nil)
        let inbox = PricingInbox(ledger: ledger, applicationSupportDirectory: root, bundledCatalogData: bundledData())
        try await inbox.start()
        let outside = root.appending(path: "outside.json")
        let sentinel = Data("outside".utf8)
        try sentinel.write(to: outside)
        let current = root.appending(path: "Pricing/current-tokenboard-pricing.json")
        try FileManager.default.removeItem(at: current)
        try FileManager.default.createSymbolicLink(at: current, withDestinationURL: outside)

        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }

        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        let firstApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(firstApplyCalls, 1)
        try FileManager.default.removeItem(at: current)
        let archive = root.appending(path: "Pricing/Applied/nofollow.json")
        try FileManager.default.createSymbolicLink(at: archive, withDestinationURL: outside)
        await XCTAssertThrowsErrorAsync { try await inbox.applyPending() }
        XCTAssertEqual(try Data(contentsOf: outside), sentinel)
        try FileManager.default.removeItem(at: archive)
        try await inbox.applyPending()
        let finalApplyCalls = await ledger.applyCallCountValue()
        XCTAssertEqual(finalApplyCalls, 1)
    }

    func testFinalizationWritesCanonicalBytesBeforeRemovingExternalProcessingInode() async throws {
        let root = try makeRoot(label: "CleanupOrder")
        defer { try? FileManager.default.removeItem(at: root) }
        try candidateData(id: "cleanup-order").write(
            to: root.appending(path: "Pricing/Inbox/\(PricingInbox.candidateFilename)")
        )
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: PricingInboxTestLedger(latestApplied: nil),
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        let canonical = await inbox.pendingCandidate()?.canonicalJSON
        fileSystem.resetOperations()

        try await inbox.applyPending()

        let operations = fileSystem.operations()
        XCTAssertEqual(operations.count, 4)
        guard case let .moveInbox(from, processing) = operations[0] else {
            return XCTFail("first operation was not candidate isolation")
        }
        XCTAssertEqual(from, PricingInbox.candidateFilename)
        XCTAssertTrue(processing.hasPrefix(".candidate-processing-"))
        XCTAssertEqual(operations[1], .replaceCanonical(.pricing, "current-tokenboard-pricing.json"))
        XCTAssertEqual(operations[2], .installCanonical(.applied, "cleanup-order.json"))
        XCTAssertEqual(operations[3], .removeInbox(processing))
        XCTAssertEqual(
            try Data(contentsOf: root.appending(path: "Pricing/Applied/cleanup-order.json")),
            canonical
        )
    }

    func testStopAndStartFailureCloseRetainedDirectoriesExactlyOnce() async throws {
        let root = try makeRoot(label: "CloseOnce")
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = RecordingPricingInboxFileSystem()
        let inbox = PricingInbox(
            ledger: PricingInboxTestLedger(latestApplied: nil),
            applicationSupportDirectory: root,
            bundledCatalogData: bundledData(),
            fileSystem: fileSystem
        )
        try await inbox.start()
        try await inbox.stop()
        try await inbox.stop()
        XCTAssertEqual(fileSystem.closeCallCount(), 1)

        let failingRoot = try makeRoot(label: "StartFailure")
        defer { try? FileManager.default.removeItem(at: failingRoot) }
        let failingFileSystem = RecordingPricingInboxFileSystem()
        failingFileSystem.failNext(.duplicateInboxDescriptor)
        let failingInbox = PricingInbox(
            ledger: PricingInboxTestLedger(latestApplied: nil),
            applicationSupportDirectory: failingRoot,
            bundledCatalogData: bundledData(),
            fileSystem: failingFileSystem
        )
        await XCTAssertThrowsErrorAsync { try await failingInbox.start() }
        XCTAssertEqual(failingFileSystem.closeCallCount(), 1)
    }

    func testProcessingCleanupIsIdempotentForFinalizationRetry() throws {
        let root = try makeRoot(label: "IdempotentCleanup")
        defer { try? FileManager.default.removeItem(at: root) }
        let processingName = ".candidate-processing-idempotent.json"
        try candidateData(id: "cleanup").write(to: root.appending(path: "Pricing/Inbox/\(processingName)"))
        let fileSystem = POSIXPricingInboxFileSystem()
        try fileSystem.open(rootPath: root.path)
        defer { fileSystem.close() }

        try fileSystem.removeInbox(name: processingName)

        XCTAssertNoThrow(try fileSystem.removeInbox(name: processingName))
    }

    private func makeSetup(latestApplied: Data? = nil, bundledCatalogData: Data? = nil) throws -> InboxSetup {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TokenboardPricingInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ledger = PricingInboxTestLedger(latestApplied: latestApplied)
        let inbox = PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: root,
            bundledCatalogData: bundledCatalogData ?? bundledData()
        )
        return InboxSetup(root: root, ledger: ledger, inbox: inbox)
    }

    private func bundledData() -> Data {
        Data(#"{"schemaVersion":1,"catalogID":"bundled-test","generatedAt":"2026-08-05T00:00:00Z","origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},"models":[]}"#.utf8)
    }

    private func candidateData(id: String) -> Data {
        Data(#"{"schemaVersion":1,"catalogID":"\#(id)","generatedAt":"2026-08-05T00:00:00Z","origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},"models":[{"provider":"codex","canonicalModelID":"gpt-test","aliases":[{"observedModelID":"gpt-test","effectiveFrom":"2026-01-01","effectiveTo":null}],"rates":[{"effectiveFrom":"2026-01-01","effectiveTo":null,"prices":{"input_uncached":"5.00","output":"30.00"},"provenanceURL":"https://openai.com/api/pricing/","verifiedAt":"2026-08-05"}]}]}"#.utf8)
    }

    private func makeRoot(label: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "TokenboardPricingInbox\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appending(path: "Pricing/Inbox"), withIntermediateDirectories: true)
        return root
    }

    private func processingNames(in root: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(
            atPath: root.appending(path: "Pricing/Inbox").path
        ).filter { $0.hasPrefix(PricingInbox.processingFilenamePrefix) }.sorted()
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
    func applyCallCountValue() -> Int { applyCalls }
    func snapshotCallCount() -> Int { snapshotCalls }
    func snapshotCallCountValue() -> Int { snapshotCalls }
    func lastAppliedCatalogID() -> String? { appliedCatalogID }
}

private actor SuspendingPricingLedger: LedgerStore {
    private var latest: Data?
    private var applyCalls = 0
    private var applyStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func migrate() {}
    func commit(_ usage: [NormalizedUsage], skipped: [SkippedRecord], checkpoint: SourceCheckpoint, calendar: Calendar) {}
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func checkpoint(for fingerprint: String) -> SourceCheckpoint? { nil }
    func sourceFingerprint(provider: Provider, stableID: String) -> String { "unused" }
    func recordIdentityHash(_ value: String) -> String { "unused" }
    func pricingSnapshot() -> PricingSnapshot { PricingSnapshot(catalogIDs: [], rates: [], aliases: []) }
    func latestAppliedPricingCatalogJSON() -> Data? { latest }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) async {
        applyCalls += 1
        applyStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        latest = canonicalJSON
    }
    func waitUntilApplyStarted() async {
        if applyStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumeApply() { resumeContinuation?.resume(); resumeContinuation = nil }
    func applyCallCountValue() -> Int { applyCalls }
}

private actor SuspendingFailPricingLedger: LedgerStore {
    private var applyStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func migrate() {}
    func commit(_ usage: [NormalizedUsage], skipped: [SkippedRecord], checkpoint: SourceCheckpoint, calendar: Calendar) {}
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func checkpoint(for fingerprint: String) -> SourceCheckpoint? { nil }
    func sourceFingerprint(provider: Provider, stableID: String) -> String { "unused" }
    func recordIdentityHash(_ value: String) -> String { "unused" }
    func pricingSnapshot() -> PricingSnapshot { PricingSnapshot(catalogIDs: [], rates: [], aliases: []) }
    func latestAppliedPricingCatalogJSON() -> Data? { nil }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) async throws {
        applyStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { resumeContinuation = $0 }
        throw FailOncePricingLedgerError.injected
    }
    func waitUntilApplyStarted() async {
        if applyStarted { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }
    func resumeApply() { resumeContinuation?.resume(); resumeContinuation = nil }
}

private enum FailOncePricingLedgerError: Error { case injected }

private actor QuiescenceCompletion {
    private var completed = false

    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor FailOncePricingLedger: LedgerStore {
    private var latest: Data?
    private var applyCalls = 0

    func migrate() {}
    func commit(_ usage: [NormalizedUsage], skipped: [SkippedRecord], checkpoint: SourceCheckpoint, calendar: Calendar) {}
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func checkpoint(for fingerprint: String) -> SourceCheckpoint? { nil }
    func sourceFingerprint(provider: Provider, stableID: String) -> String { "unused" }
    func recordIdentityHash(_ value: String) -> String { "unused" }
    func pricingSnapshot() -> PricingSnapshot { PricingSnapshot(catalogIDs: [], rates: [], aliases: []) }
    func latestAppliedPricingCatalogJSON() -> Data? { latest }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        applyCalls += 1
        if applyCalls == 1 { throw FailOncePricingLedgerError.injected }
        latest = canonicalJSON
    }
    func applyCallCountValue() -> Int { applyCalls }
}

private enum RecordedPricingFileSystemOperation: Equatable {
    case duplicateInboxDescriptor
    case moveInbox(String, String)
    case replaceCanonical(PricingInboxDirectory, String)
    case installCanonical(PricingInboxDirectory, String)
    case removeInbox(String)
}

private final class DirectorySyncFailureInjector: @unchecked Sendable {
    private let lock = NSLock()
    private var attempt = 0
    private var failureAttempt: Int?

    func fail(atAttempt attempt: Int) {
        lock.withLock {
            self.attempt = 0
            failureAttempt = attempt
        }
    }

    func call(_ descriptor: Int32) -> Int32 {
        let shouldFail = lock.withLock { () -> Bool in
            attempt += 1
            guard failureAttempt == attempt else { return false }
            failureAttempt = nil
            return true
        }
        return shouldFail ? -1 : Darwin.fsync(descriptor)
    }

    func attemptCount() -> Int { lock.withLock { attempt } }
}

private final class RecordingPricingInboxFileSystem: PricingInboxFileSystem, @unchecked Sendable {
    private let base = POSIXPricingInboxFileSystem()
    private let lock = NSLock()
    private var recorded: [RecordedPricingFileSystemOperation] = []
    private var failures: [RecordedPricingFileSystemOperation] = []
    private var closeCalls = 0

    func open(rootPath: String) throws { try base.open(rootPath: rootPath) }
    func close() {
        lock.withLock { closeCalls += 1 }
        base.close()
    }
    func duplicateInboxDescriptor() throws -> Int32 {
        try record(.duplicateInboxDescriptor)
        return try base.duplicateInboxDescriptor()
    }
    func readIfPresent(
        in directory: PricingInboxDirectory,
        name: String
    ) throws -> PricingInboxOpenedFile? {
        try base.readIfPresent(in: directory, name: name)
    }
    func listInbox() throws -> [String] { try base.listInbox() }
    func moveInbox(from: String, to: String, exclusive: Bool) throws {
        try record(.moveInbox(from, to))
        try base.moveInbox(from: from, to: to, exclusive: exclusive)
    }
    func replaceCanonical(_ data: Data, in directory: PricingInboxDirectory, name: String) throws {
        try record(.replaceCanonical(directory, name))
        try base.replaceCanonical(data, in: directory, name: name)
    }
    func installCanonicalIfAbsent(
        _ data: Data,
        in directory: PricingInboxDirectory,
        name: String
    ) throws -> Bool {
        try record(.installCanonical(directory, name))
        return try base.installCanonicalIfAbsent(data, in: directory, name: name)
    }
    func removeInbox(name: String) throws {
        try record(.removeInbox(name))
        try base.removeInbox(name: name)
    }

    func failNext(_ operation: RecordedPricingFileSystemOperation) {
        lock.withLock { failures.append(operation) }
    }
    func resetOperations() { lock.withLock { recorded.removeAll() } }
    func operations() -> [RecordedPricingFileSystemOperation] { lock.withLock { recorded } }
    func closeCallCount() -> Int { lock.withLock { closeCalls } }

    private func record(_ operation: RecordedPricingFileSystemOperation) throws {
        let shouldFail = lock.withLock { () -> Bool in
            if let index = failures.firstIndex(of: operation) {
                failures.remove(at: index)
                return true
            }
            if operation != .duplicateInboxDescriptor { recorded.append(operation) }
            return false
        }
        if shouldFail { throw PricingInboxError.fileOperationFailed("injected filesystem failure") }
    }
}

private func assertInboxError(
    _ expected: PricingInboxError,
    operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch let error as PricingInboxError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

private func XCTAssertThrowsErrorAsync(
    _ operation: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await operation()
        XCTFail("expected error", file: file, line: line)
    } catch {}
}

private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<100 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return false
}
