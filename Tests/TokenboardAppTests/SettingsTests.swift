import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class SettingsTests: XCTestCase {
    func testRecoveryLoadsBackupWithoutRestoringUntilExplicitActionAndUsesShutdownBarrier() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let backup = recoveryFiles.backup
        let recovery = SettingsRecovery(backup: backup)
        let setup = try makeSetup(candidate: nil, databaseRecovery: recovery)
        defer { setup.cleanup() }
        var failed = setup.model.state
        failed.lifecycle = .failed(message: TokenboardHealth.Issue.integrityFailure.message)
        failed.health = failed.health.replacing(
            database: .recoveryRequired(
                message: TokenboardHealth.Issue.integrityFailure.message
            )
        )
        setup.model.commitState(failed)

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.recoveryBackups, [backup])
        let restoresBeforeAction = await recovery.restoreCount()
        XCTAssertEqual(restoresBeforeAction, 0)

        await setup.model.restoreLatestBackup()

        let restoresAfterAction = await recovery.restoreCount()
        let didAwaitShutdown = await recovery.didAwaitShutdown()
        XCTAssertEqual(restoresAfterAction, 1)
        XCTAssertTrue(didAwaitShutdown)
        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("restored and verified") == true)
    }

    private func makeRecoveryBackup() async throws -> (root: URL, backup: DatabaseBackup) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(
            path: "SettingsTests-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let backups = root.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        try Data("current".utf8).write(to: root.appending(path: "ledger.sqlite"))
        try Data("backup".utf8).write(
            to: backups.appending(path: "ledger-v1-100.sqlite")
        )
        let service = DatabaseRecoveryService(
            databaseURL: root.appending(path: "ledger.sqlite"),
            backupDirectory: backups
        )
        let available = try await service.availableBackups()
        let backup = try XCTUnwrap(available.first)
        return (root, backup)
    }

    func testRecoveryBarrierFailurePreventsRestoreMutation() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(backup: recoveryFiles.backup)
        let setup = try makeSetup(
            candidate: nil,
            ledgerShutdownError: SettingsError.injected,
            databaseRecovery: recovery
        )
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreLatestBackup()

        let mutationCount = await recovery.mutationCount()
        let didAwaitShutdown = await recovery.didAwaitShutdown()
        XCTAssertEqual(mutationCount, 0)
        XCTAssertFalse(didAwaitShutdown)
        XCTAssertEqual(setup.model.state.lifecycle, .shuttingDown)
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("failed safely") == true)

        await setup.model.restoreLatestBackup()

        let retryMutations = await recovery.mutationCount()
        let retryShutdownCount = await setup.ledger.shutdownCount()
        let writerStarts = await setup.inbox.startCount()
        XCTAssertEqual(retryMutations, 1)
        XCTAssertEqual(retryShutdownCount, 2)
        XCTAssertEqual(writerStarts, 0)
        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
    }

    func testTerminationRefusesStrictCloseFailureAndCanRetryWithoutRestartingWriters() async throws {
        let setup = try makeSetup(
            candidate: nil,
            ledgerShutdownError: SettingsError.injected
        )
        defer { setup.cleanup() }
        await setup.model.start()

        let first = await setup.model.shutdown()

        XCTAssertFalse(first)
        XCTAssertEqual(setup.model.state.lifecycle, .shuttingDown)
        let startsAfterFailure = await setup.inbox.startCount()
        XCTAssertEqual(startsAfterFailure, 1)

        let second = await setup.model.shutdown()

        XCTAssertTrue(second)
        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        let startsAfterRetry = await setup.inbox.startCount()
        let shutdownsAfterRetry = await setup.ledger.shutdownCount()
        XCTAssertEqual(startsAfterRetry, 1)
        XCTAssertEqual(shutdownsAfterRetry, 2)
    }

    func testShutdownWaitsForRetainedRestoreAcrossRecoveryPhases() async throws {
        for phase in ["replacement", "validation", "rollback"] {
            let recoveryFiles = try await makeRecoveryBackup()
            defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
            let gate = SettingsMutationGate()
            let recovery = SettingsRecovery(backup: recoveryFiles.backup, stageGate: gate)
            let setup = try makeSetup(candidate: nil, databaseRecovery: recovery)
            defer { setup.cleanup() }
            publishRecoveryRequired(in: setup.model)
            await setup.model.refreshSettings()

            let restore = Task { await setup.model.restoreLatestBackup() }
            await gate.waitUntilEntered()
            let completion = SettingsCompletionFlag()
            let shutdown = Task {
                await setup.model.shutdown()
                await completion.markCompleted()
            }
            try? await Task.sleep(for: .milliseconds(20))
            let completedEarly = await completion.isCompleted()
            XCTAssertFalse(completedEarly, "termination escaped during \(phase)")

            await gate.release()
            await restore.value
            await shutdown.value
            let completed = await completion.isCompleted()
            XCTAssertTrue(completed)
            XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        }
    }

    func testShutdownAwaitsPricingApplyBeforeInboxQuiescenceAndLedgerClose() async throws {
        let applyGate = SettingsMutationGate()
        let setup = try makeSetup(
            candidate: validatedCandidate(),
            pricingApplyGate: applyGate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        setup.recorder.reset()

        let apply = Task { await setup.model.applyPendingPricing() }
        await applyGate.waitUntilEntered()
        let shutdown = Task { await setup.model.shutdown() }
        try? await Task.sleep(for: .milliseconds(20))
        let shutdownCount = await setup.ledger.shutdownCount()
        XCTAssertEqual(shutdownCount, 0)
        XCTAssertFalse(setup.recorder.snapshot.contains("inbox.quiesce"))

        await applyGate.release()
        await apply.value
        _ = await shutdown.value
        let events = setup.recorder.snapshot
        let applyComplete = try XCTUnwrap(events.firstIndex(of: "inbox.apply.complete"))
        let quiesce = try XCTUnwrap(events.firstIndex(of: "inbox.quiesce"))
        let stop = try XCTUnwrap(events.firstIndex(of: "inbox.stop"))
        let close = try XCTUnwrap(events.firstIndex(of: "ledger.shutdown"))
        XCTAssertTrue(applyComplete < quiesce)
        XCTAssertTrue(quiesce < stop)
        XCTAssertTrue(stop < close)
    }

    private func publishRecoveryRequired(in model: AppModel) {
        var failed = model.state
        failed.lifecycle = .failed(message: TokenboardHealth.Issue.integrityFailure.message)
        failed.health = failed.health.replacing(
            database: .recoveryRequired(
                message: TokenboardHealth.Issue.integrityFailure.message
            )
        )
        model.commitState(failed)
    }

    func testRefreshingSettingsWaitsForStartupWhenOpenedOnDemand() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.state.lifecycle, .ready)
        XCTAssertNotNil(setup.model.settingsState.pricing.preview)
    }

    func testRefreshingSettingsBuildsAReviewWithoutApplyingTheCandidate() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.pricing.preview?.currentKnownUSD, .zero)
        XCTAssertEqual(
            setup.model.settingsState.pricing.preview?.candidateKnownUSD,
            Decimal(string: "0.20")
        )
        XCTAssertEqual(setup.model.settingsState.pricing.preview?.newlyPricedTokens, 100_000)
        XCTAssertEqual(setup.model.settingsState.pricing.unpricedModels, ["codex/gpt-preview"])
        XCTAssertEqual(setup.model.settingsState.diagnostics.skippedRecordCount, 3)
        XCTAssertEqual(
            setup.model.settingsState.diagnostics.parserVersions,
            [.claudeCode: ClaudeCodeAdapter.parserVersion, .codex: CodexAdapter.parserVersion]
        )
        let inboxCounts = await setup.inbox.counts()
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertEqual(inboxCounts.reject, 0)
    }

    func testApplyRequiresConflictFreePreviewThenRefreshesTheSelectedSummary() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let queryCountBeforeApply = await setup.query.callCount()

        await setup.model.applyPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        let queryCountAfterApply = await setup.query.callCount()
        XCTAssertEqual(inboxCounts.apply, 1)
        XCTAssertEqual(inboxCounts.reject, 0)
        XCTAssertEqual(queryCountAfterApply, queryCountBeforeApply + 1)
        XCTAssertEqual(setup.model.settingsState.pricing.pendingCandidate, nil)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing applied · API-equivalent value refreshed")
    }

    func testCommittedFinalizationPendingStillRefreshesSummaryAndPublishesSafeStatus() async throws {
        let setup = try makeSetup(
            candidate: validatedCandidate(),
            applyOutcome: .committedFinalizationPending
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let callsBefore = await setup.query.callCount()

        await setup.model.applyPendingPricing()

        let callsAfter = await setup.query.callCount()
        XCTAssertEqual(callsAfter, callsBefore + 1)
        XCTAssertEqual(
            setup.model.settingsState.statusMessage,
            "Pricing applied · File finalization will retry"
        )
    }

    func testAppliedFinalizationRetryIsReachableRefreshesSummaryAndDoesNotApplyAgain() async throws {
        let identity = PricingCandidateIdentity(canonicalJSON: Data("applied-finalizing".utf8))
        let setup = try makeSetup(
            candidate: nil,
            pricingInboxStatus: .appliedFinalizing(identity),
            finalizationOutcome: .applied
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let queriesBeforeRetry = await setup.query.callCount()

        XCTAssertEqual(setup.model.settingsState.pricing.finalizationIdentity, identity)
        XCTAssertTrue(setup.model.settingsState.pricing.canRetryFinalization)
        XCTAssertFalse(setup.model.settingsState.pricing.canApply)

        await setup.model.retryPricingFinalization()

        let counts = await setup.inbox.counts()
        let queriesAfterRetry = await setup.query.callCount()
        XCTAssertEqual(counts.apply, 0)
        XCTAssertEqual(counts.reject, 0)
        XCTAssertEqual(counts.retry, 1)
        XCTAssertEqual(queriesAfterRetry, queriesBeforeRetry + 1)
        XCTAssertEqual(setup.model.settingsState.pricing.inboxStatus, .empty)
        XCTAssertEqual(
            setup.model.settingsState.statusMessage,
            "Pricing file finalization completed"
        )
        XCTAssertFalse(setup.model.settingsState.isFinalizationRetryInProgress)
    }

    func testRejectedFinalizationRetryIsSerializedAndDoesNotMutatePricingOrSummary() async throws {
        let identity = PricingCandidateIdentity(canonicalJSON: Data("rejected-finalizing".utf8))
        let gate = SettingsMutationGate()
        let setup = try makeSetup(
            candidate: nil,
            pricingInboxStatus: .rejectedFinalizing(identity),
            finalizationOutcome: .rejected,
            finalizationRetryGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let pricingBefore = await setup.ledger.currentPricing()
        let queriesBeforeRetry = await setup.query.callCount()

        let first = Task { await setup.model.retryPricingFinalization() }
        await gate.waitUntilEntered()
        XCTAssertTrue(setup.model.settingsState.isFinalizationRetryInProgress)
        XCTAssertFalse(setup.model.settingsState.pricing.canRetryFinalization)
        let second = Task { await setup.model.retryPricingFinalization() }
        await Task.yield()
        await gate.release()
        await first.value
        await second.value

        let counts = await setup.inbox.counts()
        let pricingAfter = await setup.ledger.currentPricing()
        let queriesAfterRetry = await setup.query.callCount()
        XCTAssertEqual(counts.apply, 0)
        XCTAssertEqual(counts.reject, 0)
        XCTAssertEqual(counts.retry, 1)
        XCTAssertEqual(pricingAfter, pricingBefore)
        XCTAssertEqual(queriesAfterRetry, queriesBeforeRetry)
        XCTAssertEqual(setup.model.settingsState.pricing.inboxStatus, .empty)
        XCTAssertEqual(
            setup.model.settingsState.statusMessage,
            "Rejected candidate file finalization completed"
        )
        XCTAssertFalse(setup.model.settingsState.isFinalizationRetryInProgress)
    }

    func testFinalizationRetryFailureKeepsActionReachableAndPublishesSanitizedError() async throws {
        let identity = PricingCandidateIdentity(canonicalJSON: Data("retry-failure".utf8))
        let setup = try makeSetup(
            candidate: nil,
            pricingInboxStatus: .appliedFinalizing(identity),
            finalizationRetryError: .fileOperationFailed("private candidate path")
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()

        await setup.model.retryPricingFinalization()

        XCTAssertEqual(
            setup.model.settingsState.statusMessage,
            "Pricing finalization retry failed · Files remain safely pending"
        )
        XCTAssertFalse(setup.model.settingsState.statusMessage?.contains("private") == true)
        XCTAssertEqual(
            setup.model.settingsState.pricing.inboxStatus,
            .appliedFinalizing(identity)
        )
        XCTAssertTrue(setup.model.settingsState.pricing.canRetryFinalization)
        XCTAssertFalse(setup.model.settingsState.isFinalizationRetryInProgress)
    }

    func testInvalidInboxStatusIsVisibleAndApplyRemainsDisabled() async throws {
        let setup = try makeSetup(
            candidate: nil,
            pricingInboxStatus: .invalid(.invalidCatalog)
        )
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.pricing.inboxStatus, .invalid(.invalidCatalog))
        XCTAssertNil(setup.model.settingsState.pricing.pendingCandidate)
        XCTAssertFalse(setup.model.settingsState.pricing.canApply)
        XCTAssertEqual(
            setup.model.health.pricing,
            .warning(message: TokenboardHealth.Issue.invalidPricingCandidate.message)
        )
        XCTAssertEqual(setup.model.settingsState.diagnostics.health, setup.model.health)
    }

    func testConflictBlocksApplyAndLeavesCandidatePending() async throws {
        let current = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [storedRate(usd: "1")],
            aliases: [storedAlias()]
        )
        let setup = try makeSetup(candidate: validatedCandidate(), pricing: current)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()

        await setup.model.applyPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        XCTAssertFalse(setup.model.settingsState.pricing.canApply)
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertNotNil(setup.model.settingsState.pricing.pendingCandidate)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing candidate has conflicts that block Apply")
    }

    func testRejectArchivesCandidateWithoutMutatingThePricingLedger() async throws {
        let setup = try makeSetup(candidate: validatedCandidate())
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        let pricingBefore = await setup.ledger.currentPricing()

        await setup.model.rejectPendingPricing()

        let inboxCounts = await setup.inbox.counts()
        let pricingAfter = await setup.ledger.currentPricing()
        XCTAssertEqual(inboxCounts.reject, 1)
        XCTAssertEqual(inboxCounts.apply, 0)
        XCTAssertEqual(pricingAfter, pricingBefore)
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Pricing candidate rejected · Active pricing unchanged")
    }

    func testCopyPromptExportsFirstAndWritesOnePlainTextStringWithExactPaths() async throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }
        await setup.model.start()
        setup.recorder.reset()

        await setup.model.copyAgentPrompt(source: .officialResearch)

        XCTAssertEqual(setup.recorder.snapshot, ["inbox.export", "pasteboard.replace"])
        XCTAssertEqual(setup.pasteboard.values.count, 1)
        let prompt = try XCTUnwrap(setup.pasteboard.values.first)
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "current-tokenboard-pricing.json").path))
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "Inbox/tokenboard-pricing.candidate.json.tmp").path))
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "Inbox/tokenboard-pricing.candidate.json").path))
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Prompt copied · Tokenboard made no network request")
    }

    func testChangeReconfiguresOnlyTheSelectedProvider() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appending(path: "SettingsTests-replacement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        await setup.model.changeSource(.claudeCode)

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.replacedProviders, [.claudeCode])
        XCTAssertEqual(evidence.stopped, 0)
        XCTAssertEqual(evidence.lastRoots?[.claudeCode], replacement.standardizedFileURL)
        XCTAssertTrue(setup.model.hasActiveGrant(for: .codex))
    }

    func testRevokeStopsOnlySelectedSourceAndRetainsLedgerRowsAndOtherGrant() async throws {
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let rowsBefore = await setup.ledger.currentRows()
        await setup.coordinator.resetEvidence()

        await setup.model.revokeSource(.claudeCode)

        let evidence = await setup.coordinator.evidence()
        let rowsAfter = await setup.ledger.currentRows()
        XCTAssertEqual(evidence.revokedProviders, [.claudeCode])
        XCTAssertEqual(evidence.lastRoots?.keys.sorted(by: { $0.rawValue < $1.rawValue }), [.codex])
        XCTAssertFalse(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertTrue(setup.model.hasActiveGrant(for: .codex))
        XCTAssertEqual(setup.model.sourceHealth[.claudeCode], .notGranted)
        XCTAssertEqual(rowsAfter, rowsBefore)
        XCTAssertNil(try setup.grantStore.grant(for: .claudeCode))
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testChangingTheRemainingSourceAfterRevokeReconfiguresItsWatcher() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appending(path: "SettingsTests-single-replacement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.revokeSource(.claudeCode)
        await setup.coordinator.resetEvidence()

        await setup.model.changeSource(.codex)

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.replacedProviders, [.codex])
        XCTAssertEqual(evidence.lastRoots, [.codex: replacement.standardizedFileURL])
        XCTAssertEqual(evidence.stopped, 0)
    }

    func testChangeThenRevokeSharesOneMutationAndKeepsReplacementGrantAtomic() async throws {
        let gate = SettingsMutationGate()
        let replacement = URL(fileURLWithPath: "/private/tmp/change-wins", isDirectory: true)
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement,
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let change = Task { await setup.model.changeSource(.claudeCode) }
        await gate.waitUntilEntered()
        XCTAssertTrue(setup.model.settingsState.isSourceMutationInProgress)
        let revoke = Task { await setup.model.revokeSource(.claudeCode) }
        await Task.yield()
        await gate.release()
        await change.value
        await revoke.value

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.replacedProviders, [.claudeCode])
        XCTAssertEqual(evidence.revokedProviders, [])
        XCTAssertTrue(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertEqual(
            try setup.grantStore.grant(for: .claudeCode)?.lastPathComponent,
            replacement.lastPathComponent
        )
        XCTAssertEqual(setup.access.stopCount, 1)
        XCTAssertFalse(setup.model.settingsState.isSourceMutationInProgress)
    }

    func testRevokeThenChangeSharesOneMutationAndKeepsRevocationAtomic() async throws {
        let gate = SettingsMutationGate()
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: URL(fileURLWithPath: "/private/tmp/change-loses", isDirectory: true),
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let revoke = Task { await setup.model.revokeSource(.claudeCode) }
        await gate.waitUntilEntered()
        let change = Task { await setup.model.changeSource(.claudeCode) }
        await Task.yield()
        await gate.release()
        await revoke.value
        await change.value

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.revokedProviders, [.claudeCode])
        XCTAssertEqual(evidence.replacedProviders, [])
        XCTAssertFalse(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertNil(try setup.grantStore.grant(for: .claudeCode))
        XCTAssertEqual(setup.access.stopCount, 1)
    }

    func testConcurrentRevokesShareOneMutationAndCloseGrantOnce() async throws {
        let gate = SettingsMutationGate()
        let setup = try makeSetup(
            candidate: nil,
            grantedProviders: Set(Provider.allCases),
            approved: true,
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let first = Task { await setup.model.revokeSource(.claudeCode) }
        await gate.waitUntilEntered()
        let second = Task { await setup.model.revokeSource(.claudeCode) }
        await Task.yield()
        await gate.release()
        await first.value
        await second.value

        let evidence = await setup.coordinator.evidence()
        XCTAssertEqual(evidence.revokedProviders, [.claudeCode])
        XCTAssertEqual(setup.access.stopCount, 1)
        XCTAssertNil(try setup.grantStore.grant(for: .claudeCode))
    }

    func testRevealLocalDataSelectsOnlyTheApplicationSupportRoot() throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }

        setup.model.revealLocalData()

        XCTAssertEqual(setup.revealer.selections, [[setup.paths.root]])
    }

    func testSettingsWindowCreatesAndReleasesSwiftUIViewStateOnDemand() async throws {
        let setup = try makeSetup(candidate: nil)
        defer { setup.cleanup() }
        let service = SettingsLoginService()
        weak var releasedController: LaunchAtLoginController?
        var creationCount = 0
        let controller = SettingsWindowController(
            model: setup.model,
            launchAtLoginFactory: {
                creationCount += 1
                let value = LaunchAtLoginController(service: service)
                releasedController = value
                return value
            }
        )

        XCTAssertFalse(controller.isSettingsViewLoaded)
        controller.showWindow(nil)
        XCTAssertTrue(controller.isSettingsViewLoaded)
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(controller.currentLaunchAtLoginEnabled, false)

        service.isEnabled = true
        controller.showWindow(nil)
        XCTAssertEqual(controller.currentLaunchAtLoginEnabled, true)

        controller.close()
        XCTAssertFalse(controller.isSettingsViewLoaded)
        for _ in 0..<20 where releasedController != nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNil(releasedController)

        controller.showWindow(nil)
        XCTAssertEqual(creationCount, 2)
        XCTAssertEqual(controller.currentLaunchAtLoginEnabled, true)
        controller.close()
    }

    func testLaunchAtLoginUsesMainAppServiceAndPublishesRegistrationErrors() throws {
        let service = SettingsLoginService()
        let controller = LaunchAtLoginController(service: service)
        XCTAssertFalse(controller.isEnabled)

        try controller.setEnabled(true)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertEqual(service.registerCount, 1)

        service.registrationError = SettingsError.injected
        do {
            try controller.setEnabled(true)
            XCTFail("expected registration failure")
        } catch SettingsError.injected {
        }
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertEqual(service.registerCount, 2)
    }

    private func makeSetup(
        candidate: ValidatedPricingCatalog?,
        pricing: PricingSnapshot = PricingSnapshot(catalogIDs: ["current"], rates: [], aliases: []),
        grantedProviders: Set<Provider> = [],
        approved: Bool = false,
        pickerURL: URL? = nil,
        coordinatorMutationGate: SettingsMutationGate? = nil,
        pricingInboxStatus: PricingInboxStatus? = nil,
        applyOutcome: PricingApplyOutcome = .finalized,
        finalizationOutcome: PricingFinalizationOutcome = .applied,
        finalizationRetryGate: SettingsMutationGate? = nil,
        finalizationRetryError: PricingInboxError? = nil,
        pricingApplyGate: SettingsMutationGate? = nil,
        ledgerShutdownError: SettingsError? = nil,
        databaseRecovery: (any AppDatabaseRecovering)? = nil
    ) throws -> SettingsSetup {
        let suite = "SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let access = SettingsBookmarkAccess()
        for provider in grantedProviders {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = URL(
                fileURLWithPath: "/private/tmp/\(suite)-\(provider.rawValue)",
                isDirectory: true
            )
        }
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        let paths = ApplicationPaths(
            root: URL(fileURLWithPath: "/private/tmp/\(suite)-Application Support", isDirectory: true)
        )
        let rows = [usageRow(quantity: 100_000)]
        let recorder = SettingsRecorder()
        let ledger = SettingsLedger(
            pricing: pricing,
            rows: rows,
            recorder: recorder,
            shutdownError: ledgerShutdownError
        )
        let inbox = SettingsInbox(
            candidate: candidate,
            ledger: ledger,
            recorder: recorder,
            forcedStatus: pricingInboxStatus,
            applyOutcome: applyOutcome,
            finalizationOutcome: finalizationOutcome,
            finalizationRetryGate: finalizationRetryGate,
            finalizationRetryError: finalizationRetryError,
            applyGate: pricingApplyGate
        )
        let query = SettingsQuery()
        let coordinator = SettingsCoordinator(mutationGate: coordinatorMutationGate)
        let pasteboard = SettingsPasteboard(recorder: recorder)
        let revealer = SettingsRevealer()
        let grantStore = SourceGrantStore(defaults: defaults, bookmarkAccess: access)
        let model = AppModel(
            ledger: ledger,
            queryService: query,
            coordinator: coordinator,
            pricingInbox: inbox,
            grantStore: grantStore,
            preferences: preferences,
            bundledCatalogData: Data([1]),
            applicationPaths: paths,
            sourcePicker: SettingsPicker(url: pickerURL),
            pasteboard: pasteboard,
            localDataRevealer: revealer,
            databaseRecovery: databaseRecovery
        )
        return SettingsSetup(
            model: model,
            ledger: ledger,
            query: query,
            coordinator: coordinator,
            inbox: inbox,
            grantStore: grantStore,
            access: access,
            paths: paths,
            pasteboard: pasteboard,
            revealer: revealer,
            recorder: recorder,
            cleanup: { defaults.removePersistentDomain(forName: suite) }
        )
    }

    private func usageRow(quantity: Int64) -> DailyUsageRow {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return DailyUsageRow(
            localDay: LocalDay(
                date: ISO8601DateFormatter().date(from: "2026-08-05T12:00:00Z")!,
                calendar: calendar
            ),
            provider: .codex,
            observedModelID: "gpt-preview",
            metric: .inputUncached,
            aggregation: .additive,
            quantity: quantity
        )
    }

    private func storedAlias() -> StoredModelAlias {
        StoredModelAlias(
            provider: .codex,
            observedModelID: "gpt-preview",
            canonicalModelID: "gpt-preview",
            effectiveFrom: "2026-01-01",
            effectiveTo: nil
        )
    }

    private func storedRate(usd: String) -> StoredPriceRate {
        StoredPriceRate(
            provider: .codex,
            canonicalModelID: "gpt-preview",
            metric: .inputUncached,
            usdPerMillion: Decimal(string: usd)!,
            effectiveFrom: "2026-01-01",
            effectiveTo: nil,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
        )
    }

    private func validatedCandidate() throws -> ValidatedPricingCatalog {
        let json = #"""
        {
          "schemaVersion":1,
          "catalogID":"candidate-2026-08-05",
          "generatedAt":"2026-08-05T12:00:00Z",
          "origin":{"kind":"official_research","url":"https://openai.com/api/pricing/"},
          "models":[{
            "provider":"codex",
            "canonicalModelID":"gpt-preview",
            "aliases":[{"observedModelID":"gpt-preview","effectiveFrom":"2026-01-01","effectiveTo":null}],
            "rates":[{
              "effectiveFrom":"2026-01-01",
              "effectiveTo":null,
              "prices":{"input_uncached":"2","output":"30"},
              "provenanceURL":"https://openai.com/api/pricing/",
              "verifiedAt":"2026-08-05"
            }]
          }]
        }
        """#
        return try PricingCatalogValidator().validate(
            PricingCatalogLoader().load(Data(json.utf8))
        )
    }
}

private struct SettingsSetup {
    let model: AppModel
    let ledger: SettingsLedger
    let query: SettingsQuery
    let coordinator: SettingsCoordinator
    let inbox: SettingsInbox
    let grantStore: SourceGrantStore
    let access: SettingsBookmarkAccess
    let paths: ApplicationPaths
    let pasteboard: SettingsPasteboard
    let revealer: SettingsRevealer
    let recorder: SettingsRecorder
    let cleanup: () -> Void
}

private enum SettingsError: Error { case injected }

private actor SettingsRecovery: AppDatabaseRecovering {
    private let backup: DatabaseBackup
    private var restores = 0
    private var shutdownAwaited = false
    private var mutations = 0
    private let stageGate: SettingsMutationGate?

    init(backup: DatabaseBackup, stageGate: SettingsMutationGate? = nil) {
        self.backup = backup
        self.stageGate = stageGate
    }

    func availableBackups() -> [DatabaseBackup] { [backup] }

    func restore(
        _ confirmedBackup: DatabaseBackup,
        afterShutdown: @Sendable () async throws -> Void
    ) async throws -> DatabaseBackup {
        guard confirmedBackup == backup else { throw SettingsError.injected }
        restores += 1
        try await afterShutdown()
        shutdownAwaited = true
        if let stageGate { await stageGate.suspend() }
        mutations += 1
        return backup
    }

    func restoreCount() -> Int { restores }
    func didAwaitShutdown() -> Bool { shutdownAwaited }
    func mutationCount() -> Int { mutations }
}

private final class SettingsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var snapshot: [String] { lock.withLock { values } }
    func append(_ value: String) { lock.withLock { values.append(value) } }
    func reset() { lock.withLock { values.removeAll() } }
}

private actor SettingsLedger: AppLedgerRuntime {
    private var pricing: PricingSnapshot
    private let rows: [DailyUsageRow]
    private let recorder: SettingsRecorder
    private var shutdownFailuresRemaining: Int
    private var shutdowns = 0

    init(
        pricing: PricingSnapshot,
        rows: [DailyUsageRow],
        recorder: SettingsRecorder,
        shutdownError: SettingsError?
    ) {
        self.pricing = pricing
        self.rows = rows
        self.recorder = recorder
        shutdownFailuresRemaining = shutdownError == nil ? 0 : 1
    }

    func migrate() {}
    func integrityCheck() {}
    func latestAppliedPricingCatalogJSON() -> Data? { Data([1]) }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {}
    func pricingSnapshot() -> PricingSnapshot { pricing }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { rows }
    func skippedRecordCount() -> Int { 3 }
    func shutdown() throws {
        shutdowns += 1
        recorder.append("ledger.shutdown")
        if shutdownFailuresRemaining > 0 {
            shutdownFailuresRemaining -= 1
            throw SettingsError.injected
        }
    }
    func shutdownCount() -> Int { shutdowns }
    func currentPricing() -> PricingSnapshot { pricing }
    func currentRows() -> [DailyUsageRow] { rows }

    func install(_ catalog: ValidatedPricingCatalog) {
        let preview = try! PricingPreview.make(rows: [], currentPricing: pricing, candidate: catalog)
        guard preview.diff.conflicts.isEmpty else { return }
        var aliases = pricing.aliases
        var rates = pricing.rates
        for model in catalog.models {
            aliases.append(contentsOf: model.aliases.map {
                StoredModelAlias(
                    provider: model.provider,
                    observedModelID: $0.observedModelID,
                    canonicalModelID: model.canonicalModelID,
                    effectiveFrom: $0.effectiveFrom,
                    effectiveTo: $0.effectiveTo
                )
            })
            for rate in model.rates {
                rates.append(contentsOf: rate.prices.map { metric, price in
                    StoredPriceRate(
                        provider: model.provider,
                        canonicalModelID: model.canonicalModelID,
                        metric: metric,
                        usdPerMillion: price,
                        effectiveFrom: rate.effectiveFrom,
                        effectiveTo: rate.effectiveTo,
                        provenanceURL: rate.provenanceURL,
                        verifiedAt: rate.verifiedAt
                    )
                })
            }
        }
        pricing = PricingSnapshot(
            catalogIDs: pricing.catalogIDs + [catalog.catalogID],
            rates: rates,
            aliases: aliases
        )
    }
}

private actor SettingsQuery: AppUsageQuerying {
    private var calls = 0
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) -> UsageSummary {
        calls += 1
        return UsageSummary(
            period: period,
            tokenTotal: 100_000,
            knownAPIEquivalentUSD: Decimal(string: "0.20")!,
            unpricedTokens: 0
        )
    }
    func callCount() -> Int { calls }
}

private actor SettingsCoordinator: AppIngestionCoordinating {
    private let mutationGate: SettingsMutationGate?
    private var runID: UInt64 = 0
    private var sequence: UInt64 = 0
    private var stopped = 0
    private var replacedProviders: [Provider] = []
    private var revokedProviders: [Provider] = []
    private var lastRoots: [Provider: URL]?

    init(mutationGate: SettingsMutationGate? = nil) {
        self.mutationGate = mutationGate
    }

    func results() -> AsyncStream<IngestionBatchResult> { AsyncStream { _ in } }
    func start(roots: [Provider: URL]) -> IngestionBatchResult {
        runID += 1
        sequence = 1
        lastRoots = roots
        return result(providers: Set(roots.keys))
    }
    func startMonitoring(roots: [Provider: URL]) -> IngestionBatchResult {
        start(roots: roots)
    }
    func refreshAll() -> IngestionBatchResult {
        sequence += 1
        return result(providers: lastRoots.map { Set($0.keys) } ?? [])
    }
    func stop() { stopped += 1 }
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) async -> IngestionBatchResult {
        if let mutationGate { await mutationGate.suspend() }
        runID += 1
        sequence = 1
        replacedProviders.append(provider)
        lastRoots = roots
        return result(providers: [provider])
    }
    func revokeSource(
        _ provider: Provider,
        remainingRoots: [Provider: URL]
    ) async -> UInt64? {
        if let mutationGate { await mutationGate.suspend() }
        revokedProviders.append(provider)
        lastRoots = remainingRoots
        guard !remainingRoots.isEmpty else { return nil }
        runID += 1
        sequence = 0
        return runID
    }
    func resetEvidence() {
        stopped = 0
        replacedProviders = []
        revokedProviders = []
    }
    func evidence() -> (
        stopped: Int,
        replacedProviders: [Provider],
        revokedProviders: [Provider],
        lastRoots: [Provider: URL]?
    ) {
        (stopped, replacedProviders, revokedProviders, lastRoots)
    }
    private func result(providers: Set<Provider>) -> IngestionBatchResult {
        IngestionBatchResult(
            runID: runID,
            sequence: sequence,
            scope: .inventory,
            providers: Dictionary(uniqueKeysWithValues: providers.map {
                ($0, .success(discoveredFiles: 0, scannedFiles: 0))
            })
        )
    }
}

private actor SettingsMutationGate {
    private var entered = false
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let observers = enteredWaiters
        enteredWaiters.removeAll()
        observers.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        released = true
        let suspended = waiters
        waiters.removeAll()
        suspended.forEach { $0.resume() }
    }
}

private actor SettingsCompletionFlag {
    private var completed = false
    func markCompleted() { completed = true }
    func isCompleted() -> Bool { completed }
}

private actor SettingsInbox: AppPricingInboxWatching {
    private var candidate: PendingPricingCandidate?
    private let ledger: SettingsLedger
    private let recorder: SettingsRecorder
    private var applyCount = 0
    private var rejectCount = 0
    private var retryCount = 0
    private var starts = 0
    private var forcedStatus: PricingInboxStatus?
    private let applyOutcome: PricingApplyOutcome
    private let finalizationOutcome: PricingFinalizationOutcome
    private let finalizationRetryGate: SettingsMutationGate?
    private let finalizationRetryError: PricingInboxError?
    private let applyGate: SettingsMutationGate?

    init(
        candidate: ValidatedPricingCatalog?,
        ledger: SettingsLedger,
        recorder: SettingsRecorder,
        forcedStatus: PricingInboxStatus? = nil,
        applyOutcome: PricingApplyOutcome = .finalized,
        finalizationOutcome: PricingFinalizationOutcome = .applied,
        finalizationRetryGate: SettingsMutationGate? = nil,
        finalizationRetryError: PricingInboxError? = nil,
        applyGate: SettingsMutationGate? = nil
    ) {
        self.ledger = ledger
        self.recorder = recorder
        self.forcedStatus = forcedStatus
        self.applyOutcome = applyOutcome
        self.finalizationOutcome = finalizationOutcome
        self.finalizationRetryGate = finalizationRetryGate
        self.finalizationRetryError = finalizationRetryError
        self.applyGate = applyGate
        if let candidate {
            self.candidate = PendingPricingCandidate(
                catalog: candidate,
                canonicalJSON: candidate.canonicalJSON,
                diff: CatalogDiff(modelsAdded: [], aliasesAdded: 0, ratesAdded: 0, conflicts: []),
                sourceURL: URL(fileURLWithPath: "/private/tmp/candidate.json")
            )
        }
    }

    func start() { starts += 1 }
    func quiesce() { recorder.append("inbox.quiesce") }
    func stop() { recorder.append("inbox.stop") }
    func pendingCandidate() -> PendingPricingCandidate? { candidate }
    func status() -> PricingInboxStatus {
        forcedStatus ?? candidate.map(PricingInboxStatus.valid) ?? .empty
    }
    func exportCurrentSnapshot() { recorder.append("inbox.export") }
    func applyPending() async {
        applyCount += 1
        recorder.append("inbox.apply.start")
        if let applyGate { await applyGate.suspend() }
        if let candidate { await ledger.install(candidate.catalog) }
        candidate = nil
        recorder.append("inbox.apply.complete")
    }
    func applyPending(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingApplyOutcome {
        guard candidate?.identity == identity else {
            throw PricingInboxError.candidateChanged
        }
        await applyPending()
        return applyOutcome
    }
    func rejectPending() { rejectCount += 1; candidate = nil }
    func rejectPending(
        matching identity: PricingCandidateIdentity
    ) throws -> PricingRejectOutcome {
        guard candidate?.identity == identity else {
            throw PricingInboxError.candidateChanged
        }
        rejectPending()
        return .finalized
    }
    func retryFinalization(
        matching identity: PricingCandidateIdentity
    ) async throws -> PricingFinalizationOutcome {
        let currentIdentity: PricingCandidateIdentity?
        switch forcedStatus {
        case let .appliedFinalizing(value), let .rejectedFinalizing(value):
            currentIdentity = value
        default:
            currentIdentity = nil
        }
        guard currentIdentity == identity else { throw PricingInboxError.candidateChanged }
        retryCount += 1
        if let finalizationRetryGate { await finalizationRetryGate.suspend() }
        if let finalizationRetryError { throw finalizationRetryError }
        forcedStatus = .empty
        return finalizationOutcome
    }
    func counts() -> (apply: Int, reject: Int, retry: Int) {
        (applyCount, rejectCount, retryCount)
    }
    func startCount() -> Int { starts }
}

@MainActor
private final class SettingsPasteboard: AppPlainTextCopying {
    private let recorder: SettingsRecorder
    private(set) var values: [String] = []
    init(recorder: SettingsRecorder) { self.recorder = recorder }
    func replace(with value: String) -> Bool {
        recorder.append("pasteboard.replace")
        values = [value]
        return true
    }
}

@MainActor
private final class SettingsRevealer: AppLocalDataRevealing {
    private(set) var selections: [[URL]] = []
    func reveal(_ urls: [URL]) { selections.append(urls) }
}

@MainActor
private struct SettingsPicker: AppSourcePicking {
    let url: URL?
    func select(provider: Provider) throws -> URL? { url }
}

private final class SettingsBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    var roots: [Data: URL] = [:]
    private(set) var stopCount = 0
    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data {
        Data(url.path.utf8)
    }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) -> ResolvedSourceBookmark {
        ResolvedSourceBookmark(
            url: roots[data] ?? URL(fileURLWithPath: String(decoding: data, as: UTF8.self)),
            isStale: false
        )
    }
    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) { stopCount += 1 }
}

@MainActor
private final class SettingsLoginService: MainAppLoginServicing {
    var isEnabled = false
    var registerCount = 0
    var unregisterCount = 0
    var registrationError: Error?
    func register() throws {
        registerCount += 1
        if let registrationError { throw registrationError }
        isEnabled = true
    }
    func unregister() throws {
        unregisterCount += 1
        isEnabled = false
    }
}
