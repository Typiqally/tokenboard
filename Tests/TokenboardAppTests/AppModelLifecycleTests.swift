import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class AppModelLifecycleTests: XCTestCase {
    func testDatabaseStartupFailuresPublishRecoveryHealthWithoutOpeningWriters() async throws {
        let cases: [(StartupFailurePoint, TokenboardHealth.Issue)] = [
            (.migrate, .migrationFailure),
            (.integrity, .integrityFailure)
        ]
        for (failure, issue) in cases {
            let setup = try makeSetup(approved: true, failure: failure)
            defer { setup.cleanup() }

            await setup.model.start()

            XCTAssertEqual(
                setup.model.health.database,
                .recoveryRequired(message: issue.message)
            )
            XCTAssertEqual(setup.model.health.claude, .notGranted)
            XCTAssertEqual(setup.model.health.codex, .notGranted)
            XCTAssertTrue(setup.model.health.hasWarning)
            let inboxCounts = await setup.inbox.counts()
            let coordinatorCounts = await setup.coordinator.counts()
            XCTAssertEqual(inboxCounts, [0, 0])
            XCTAssertEqual(coordinatorCounts, [0, 0, 0])
        }
    }

    func testShutdownClosesLedgerOnlyAfterCoordinatorAndScopesAreQuiescent() async throws {
        let stopGate = AsyncTestGate()
        let setup = try makeSetup(approved: false, coordinatorStopGate: stopGate)
        defer { setup.cleanup() }
        await setup.model.start()

        let shutdown = Task { await setup.model.shutdown() }
        await stopGate.waitUntilEntered()
        let countWhileStopping = await setup.ledger.shutdownCount()
        XCTAssertEqual(countWhileStopping, 0)
        XCTAssertEqual(setup.access.counts, [2, 0])

        await stopGate.resume()
        _ = await shutdown.value
        let countAfterStopping = await setup.ledger.shutdownCount()
        XCTAssertEqual(countAfterStopping, 1)
        XCTAssertEqual(setup.access.counts, [2, 2])

        await setup.model.shutdown()
        let countAfterDuplicate = await setup.ledger.shutdownCount()
        XCTAssertEqual(countAfterDuplicate, 1)
    }

    func testEveryFailedStartupPrerequisiteBlocksSourcesScansAndQueries() async throws {
        for point in StartupFailurePoint.allCases {
            let setup = try makeSetup(approved: true, failure: point)
            defer { setup.cleanup() }

            await setup.model.start()

            guard case .failed = setup.model.state.lifecycle else {
                return XCTFail("expected failed lifecycle for \(point)")
            }
            XCTAssertFalse(setup.model.state.canStartHistoricalImport)
            XCTAssertEqual(setup.access.counts, [0, 0])
            let coordinatorCounts = await setup.coordinator.counts()
            let queryCalls = await setup.query.calls()
            XCTAssertEqual(coordinatorCounts, [0, 0, 0])
            XCTAssertEqual(queryCalls, 0)
        }
    }

    func testRefreshRetriesNonRecoveryPrerequisitesAndSkipsAlreadyAppliedCatalog() async throws {
        let setup = try makeSetup(
            approved: false,
            failure: .latestCatalog,
            failureIsOneShot: true,
            catalogAlreadyApplied: true
        )
        defer { setup.cleanup() }
        await setup.model.start()
        guard case .failed = setup.model.state.lifecycle else {
            return XCTFail("expected first startup to fail")
        }

        await setup.model.refresh()

        XCTAssertEqual(setup.model.state.lifecycle, .ready)
        XCTAssertTrue(setup.model.state.onboardingRequired)
        let applyCount = await setup.ledger.appliedCount()
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(applyCount, 0)
        XCTAssertEqual(setup.access.counts, [2, 0])
        XCTAssertEqual(coordinatorCounts, [0, 0, 0])
    }

    func testRefreshCannotRetryDatabaseRecoveryOrRestartWriters() async throws {
        let setup = try makeSetup(
            approved: true,
            failure: .migrate,
            failureIsOneShot: true
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let migrationsBefore = await setup.ledger.migrateCount()
        let inboxBefore = await setup.inbox.counts()
        let coordinatorBefore = await setup.coordinator.counts()

        await setup.model.refresh()

        let migrationsAfter = await setup.ledger.migrateCount()
        let inboxAfter = await setup.inbox.counts()
        let coordinatorAfter = await setup.coordinator.counts()
        XCTAssertEqual(migrationsAfter, migrationsBefore)
        XCTAssertEqual(inboxAfter, inboxBefore)
        XCTAssertEqual(coordinatorAfter, coordinatorBefore)
        guard case .recoveryRequired = setup.model.health.database else {
            return XCTFail("Refresh cleared recovery-required database health")
        }
    }

    func testShutdownDuringStartupPreventsLateResourceRecreation() async throws {
        let gate = AsyncTestGate()
        let setup = try makeSetup(approved: true, startupGate: gate)
        defer { setup.cleanup() }
        let startTask = Task { await setup.model.start() }
        await gate.waitUntilEntered()

        let shutdownTask = Task { await setup.model.shutdown() }
        await Task.yield()
        await gate.resume()
        await startTask.value
        _ = await shutdownTask.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertEqual(setup.access.counts, [0, 0])
        let coordinatorCounts = await setup.coordinator.counts()
        let queryCalls = await setup.query.calls()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
        XCTAssertEqual(queryCalls, 0)
    }

    func testDoubleImportCoalescesAndShutdownDuringCoordinatorStartBalancesScopes() async throws {
        let coordinatorGate = AsyncTestGate()
        let setup = try makeSetup(approved: false, coordinatorStartGate: coordinatorGate)
        defer { setup.cleanup() }
        await setup.model.start()
        XCTAssertEqual(setup.model.state.lifecycle, .ready)

        let first = Task { await setup.model.startHistoricalImport() }
        await coordinatorGate.waitUntilEntered()
        let second = Task { await setup.model.startHistoricalImport() }
        await Task.yield()
        XCTAssertTrue(setup.model.state.isImporting)
        XCTAssertFalse(setup.model.state.canStartHistoricalImport)
        let startingCounts = await setup.coordinator.counts()
        XCTAssertEqual(startingCounts, [1, 0, 0])

        let shutdown = Task { await setup.model.shutdown() }
        await Task.yield()
        await coordinatorGate.resume()
        await first.value
        await second.value
        _ = await shutdown.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertEqual(setup.access.counts, [2, 2])
        XCTAssertNil(setup.model.state.presentation)
    }

    func testNewestPeriodQueryWinsWhenOlderQueryCompletesLast() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        await setup.query.hold(periods: [.thisWeek, .thisMonth])

        let older = Task { await setup.model.select(period: .thisWeek) }
        await setup.query.waitUntilPending(.thisWeek)
        let newer = Task { await setup.model.select(period: .thisMonth) }
        await setup.query.waitUntilPending(.thisMonth)
        await setup.query.resume(.thisMonth)
        await newer.value
        await setup.query.resume(.thisWeek)
        await older.value

        XCTAssertEqual(setup.model.state.selectedPeriod, .thisMonth)
        XCTAssertEqual(setup.model.state.presentation?.tokenTitle, "3,000 tokens")
        XCTAssertEqual(setup.preferences.selectedPeriod, .thisMonth)
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [1, 0, 0])
    }

    func testShutdownAwaitsSuspendedQueryAndRejectsItsLateResult() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        await setup.query.hold(periods: [.thisWeek])
        let selection = Task { await setup.model.select(period: .thisWeek) }
        await setup.query.waitUntilPending(.thisWeek)

        let shutdown = Task { await setup.model.shutdown() }
        await Task.yield()
        await setup.query.resume(.thisWeek)
        await selection.value
        _ = await shutdown.value

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertNil(setup.model.state.presentation)
        XCTAssertEqual(setup.access.counts, [2, 2])
    }

    func testConcurrentShutdownCallersAwaitOneBarrierAndKeepGrantsUntilQuiescent() async throws {
        let stopGate = AsyncTestGate()
        let setup = try makeSetup(approved: false, coordinatorStopGate: stopGate)
        defer { setup.cleanup() }
        await setup.model.start()
        let secondCompleted = AsyncFlag()

        let first = Task { await setup.model.shutdown() }
        await stopGate.waitUntilEntered()
        let second = Task {
            await setup.model.shutdown()
            await secondCompleted.set()
        }
        await Task.yield()

        let completedWhileStopping = await secondCompleted.value()
        XCTAssertFalse(completedWhileStopping)
        XCTAssertEqual(setup.access.counts, [2, 0])
        await stopGate.resume()
        _ = await first.value
        await second.value

        let completedAfterStop = await secondCompleted.value()
        XCTAssertTrue(completedAfterStop)
        XCTAssertEqual(setup.access.counts, [2, 2])
        var coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
        await setup.model.shutdown()
        coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [0, 0, 2])
    }

    func testShutdownReleasesQueuedManualResultBeforeAwaitingSuspendedEventQuery() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()
        await setup.query.hold(periods: [.today])
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitUntilPending(.today)

        let refreshFinished = AsyncFlag()
        let refresh = Task {
            await setup.model.refresh()
            await refreshFinished.set()
        }
        await setup.coordinator.waitForRefreshCount(1)
        let firstShutdown = Task { await setup.model.shutdown() }
        await setup.coordinator.waitForStopCount(1)
        let repeatedShutdownFinished = AsyncFlag()
        let secondShutdown = Task {
            await setup.model.shutdown()
            await repeatedShutdownFinished.set()
        }
        let refreshReleased = await refreshFinished.wait(for: .milliseconds(75))
        let repeatedReturnedEarly = await repeatedShutdownFinished.wait(for: .milliseconds(25))
        let scopesWhileQuerySuspended = setup.access.counts

        await setup.query.resume(.today)
        await refresh.value
        _ = await firstShutdown.value
        await secondShutdown.value

        XCTAssertTrue(refreshReleased)
        XCTAssertFalse(repeatedReturnedEarly)
        XCTAssertEqual(scopesWhileQuerySuspended, [2, 0])
        XCTAssertEqual(setup.access.counts, [2, 2])
        let finalQueryCalls = await setup.query.calls()
        XCTAssertEqual(finalQueryCalls, baselineCalls + 1)
    }

    func testEventBatchRequeriesOnceAndPublishesHonestProviderHealth() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let callsBeforeEvent = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [
                .claudeCode: .success(discoveredFiles: 4, scannedFiles: 1),
                .codex: .attention(discoveredFiles: 2, scannedFiles: 1)
            ],
            diagnostics: [
                .codex: ProviderIngestionDiagnostics(
                    skippedRecordCount: 0,
                    attention: [.truncated]
                )
            ]
        ))
        await waitUntil { await setup.query.calls() == callsBeforeEvent + 1 }

        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("successful provider was not healthy")
        }
        XCTAssertEqual(fileCount, 0)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 0)
        guard case let .warning(message) = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("attention outcome was mislabeled healthy")
        }
        XCTAssertEqual(message, TokenboardHealth.Issue.truncatedLog.message)
        XCTAssertNotNil(setup.model.state.lastUpdated)
    }

    func testStartupEventIsBufferedUntilCatchUpActivatesAndThenApplied() async throws {
        let startGate = AsyncTestGate()
        let setup = try makeSetup(approved: true, coordinatorStartGate: startGate)
        defer { setup.cleanup() }
        let start = Task { await setup.model.start() }
        await startGate.waitUntilEntered()
        await setup.coordinator.emit(IngestionBatchResult(
            runID: 1,
            sequence: 2,
            scope: .incremental,
            providers: [.codex: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await startGate.resume()
        await start.value
        await waitUntil {
            guard case .warning = setup.model.state.sourceHealth[.codex] else { return false }
            return true
        }

        guard case .warning = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("startup event was discarded")
        }
    }

    func testNewerIncrementalResultWinsAndPreservesFullInventoryCount() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .inventory,
            providers: [.claudeCode: .success(discoveredFiles: 8, scannedFiles: 8)]
        ))
        let inventoryCalls = calls + 1
        await waitUntil { await setup.query.calls() == inventoryCalls }
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 4,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await Task.yield()
        let bufferedCalls = await setup.query.calls()
        XCTAssertEqual(bufferedCalls, inventoryCalls)
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 3,
            scope: .inventory,
            providers: [.claudeCode: .success(discoveredFiles: 3, scannedFiles: 3)]
        ))
        await setup.query.waitForCompletedCallCount(inventoryCalls + 2)
        await waitUntil {
            setup.model.lastAppliedSequence[runID] == 4
        }

        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 3)
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("older inventory result overwrote newer attention")
        }
    }

    func testFailedIncrementalAttemptDoesNotAdvanceLastSuccessfulUpdate() async throws {
        let dates = IncrementingNow()
        let setup = try makeSetup(approved: false, now: { dates() })
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let successfulUpdate = setup.model.state.lastUpdated
        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .failure(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await waitUntil { await setup.query.calls() == calls + 1 }

        XCTAssertEqual(setup.model.state.lastUpdated, successfulUpdate)
    }

    func testIncrementalSuccessPreservesExistingWarningUntilInventorySucceeds() async throws {
        let dates = IncrementingNow()
        let setup = try makeSetup(approved: false, now: { dates() })
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitForCompletedCallCount(baselineCalls + 1)
        let warningUpdate = setup.model.state.lastUpdated
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 3,
            scope: .incremental,
            providers: [.claudeCode: .success(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitForCompletedCallCount(baselineCalls + 2)
        await waitUntil { setup.model.state.lastUpdated != warningUpdate }

        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("incremental success cleared provider attention")
        }
        XCTAssertNotEqual(setup.model.state.lastUpdated, warningUpdate)

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 4,
            scope: .inventory,
            providers: [.claudeCode: .success(discoveredFiles: 6, scannedFiles: 6)]
        ))
        await setup.query.waitForCompletedCallCount(baselineCalls + 3)
        await waitUntil {
            setup.model.state.sourceFileCounts[.claudeCode] == 6
        }
        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("successful inventory did not clear attention")
        }
        XCTAssertEqual(fileCount, 6)
    }

    func testWarningPreservesIndependentLastSuccessfulScanInSettings() async throws {
        let dates = IncrementingNow()
        let setup = try makeSetup(approved: false, now: { dates() })
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let successfulScan = setup.model.state.lastSuccessfulScans[.claudeCode]
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitForCompletedCallCount(baselineCalls + 1)
        await setup.model.refreshSettings()

        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("attention did not remain visible")
        }
        XCTAssertNotNil(successfulScan)
        XCTAssertEqual(
            setup.model.settingsState.sources[.claudeCode]?.lastScan,
            successfulScan
        )
    }

    func testManualRefreshQueuedBehindSuspendedEventAppliesInSequenceOnce() async throws {
        let setup = try makeSetup(approved: false)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()
        await setup.query.hold(periods: [.today])
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitUntilPending(.today)
        let refresh = Task { await setup.model.refresh() }
        await setup.coordinator.waitForRefreshCount(1)

        await setup.query.resume(.today)
        await refresh.value

        let finalQueryCalls = await setup.query.calls()
        XCTAssertEqual(finalQueryCalls, baselineCalls + 2)
        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("manual inventory did not follow the event warning")
        }
        XCTAssertEqual(fileCount, 0)
    }

    func testLaterEventObservedBeforeReturnedInventoryStillAppliesBothContiguously() async throws {
        let refreshGate = AsyncTestGate()
        let setup = try makeSetup(
            approved: false,
            coordinatorRefreshGate: refreshGate,
            refreshInventoryCount: 8
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        let refresh = Task { await setup.model.refresh() }
        await refreshGate.waitUntilEntered()
        let event = IngestionBatchResult(
            runID: runID,
            sequence: 3,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        )
        await setup.coordinator.emit(event)
        await waitUntil {
            setup.model.pendingIngestionResults[IngestionResultKey(
                runID: runID,
                sequence: event.sequence
            )] != nil || setup.model.lastAppliedSequence[runID, default: 0] >= event.sequence
        }

        await refreshGate.resume()
        await refresh.value

        let finalCalls = await setup.query.calls()
        XCTAssertEqual(finalCalls, baselineCalls + 2)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 8)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.codex], 8)
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("incremental event was not applied after authoritative inventory")
        }
        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.codex] else {
            return XCTFail("authoritative inventory was lost")
        }
        XCTAssertEqual(fileCount, 8)
    }

    func testRecoveryMarkerDoesNotSkipOutstandingManualInventory() async throws {
        let refreshGate = AsyncTestGate()
        let setup = try makeSetup(
            approved: false,
            coordinatorRefreshGate: refreshGate,
            refreshInventoryCount: 9
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        let refresh = Task { await setup.model.refresh() }
        await refreshGate.waitUntilEntered()
        let marker = IngestionBatchResult(
            runID: runID,
            sequence: 4,
            scope: .incremental,
            requiresInventoryRefresh: true,
            providers: [:]
        )
        await setup.coordinator.emit(marker)
        await waitUntil {
            setup.model.pendingIngestionResults[IngestionResultKey(
                runID: runID,
                sequence: marker.sequence
            )] != nil
        }

        await refreshGate.resume()
        await refresh.value
        await setup.query.waitForCompletedCallCount(baselineCalls + 2)
        await waitUntil {
            setup.model.lastAppliedSequence[runID] == 5
        }

        let coordinatorCounts = await setup.coordinator.counts()
        let finalQueryCalls = await setup.query.calls()
        XCTAssertEqual(coordinatorCounts[1], 2)
        XCTAssertEqual(finalQueryCalls, baselineCalls + 2)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 9)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.codex], 9)
    }

    func testFailedSourceReplacementPreservesOldBookmarkGrantAndPublishedState() async throws {
        let replacement = URL(fileURLWithPath: "/tmp/replacement-failure", isDirectory: true)
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            discoveryFailureRoot: replacement
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        let coordinatorCounts = await setup.coordinator.counts()
        XCTAssertEqual(coordinatorCounts, [1, 0, 0])
        XCTAssertEqual(setup.access.counts, [3, 1])
    }

    func testSuccessfulSourceReplacementStopsCoordinatorBeforeClosingOldGrant() async throws {
        let replacement = URL(fileURLWithPath: "/tmp/replacement-success", isDirectory: true)
        let recorder = ReplacementRecorder()
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            replacementRecorder: recorder
        )
        defer { setup.cleanup() }
        await setup.model.start()
        recorder.reset()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([9]))
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 2)
        let events = recorder.snapshot
        guard let stopIndex = events.firstIndex(of: "coordinator.stop"),
              let closeIndex = events.firstIndex(of: "grant.stop.claude_code") else {
            return XCTFail("missing replacement lifetime events: \(events)")
        }
        XCTAssertTrue(stopIndex < closeIndex)

        let runID = await setup.coordinator.runID()
        let calls = await setup.query.calls()
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await waitUntil { await setup.query.calls() == calls + 1 }
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("replacement runtime did not receive events")
        }
    }

    func testOverlappingReplacementIsRejectedBeforeStopBookmarkOrOldGrantMutation() async throws {
        let setup = try makeSetup(
            approved: true,
            pickedSource: URL(fileURLWithPath: "/tmp", isDirectory: true)
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")
        let priorCounts = await setup.coordinator.counts()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        let finalCounts = await setup.coordinator.counts()
        XCTAssertEqual(finalCounts, priorCounts)
        XCTAssertEqual(setup.access.counts, [3, 1])
    }

    func testFirstSourceGrantSucceedsBeforeACompleteRootPairExists() async throws {
        let source = URL(fileURLWithPath: "/tmp/replacement-first-source", isDirectory: true)
        let setup = try makeSetup(
            approved: false,
            grantedProviders: [],
            pickedSource: source
        )
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.chooseSource(.claudeCode)

        XCTAssertTrue(setup.model.hasActiveGrant(for: .claudeCode))
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), Data([9]))
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 2)
        XCTAssertEqual(setup.model.state.grantedProviders, [.claudeCode])
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [0, 0, 0])
    }

    func testApprovedSingleStoredGrantStartsCatchUpAndManualRefresh() async throws {
        let setup = try makeSetup(
            approved: true,
            grantedProviders: [.codex]
        )
        defer { setup.cleanup() }

        await setup.model.start()

        var counts = await setup.coordinator.counts()
        let roots = await setup.coordinator.activeRoots()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertEqual(Set(roots.keys), [.codex])
        XCTAssertTrue(setup.model.state.onboardingRequired)

        await setup.model.refresh()

        counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [1, 1, 0])
    }

    func testApprovedTwoToOneRevokeRelaunchRestoresRemainingRuntime() async throws {
        let setup = try makeSetup(approved: true)
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.revokeSource(.claudeCode)
        XCTAssertNil(setup.defaults.data(forKey: "sourceBookmark.claude_code"))
        XCTAssertNotNil(setup.defaults.data(forKey: "sourceBookmark.codex"))
        await setup.model.shutdown()

        let relaunchedCoordinator = LifecycleCoordinator(
            startGate: nil,
            startGateCall: 1,
            refreshGate: nil,
            stopGate: nil,
            stopGateCall: 1,
            failingStartRoot: nil,
            recorder: nil,
            restoredInventoryCount: nil,
            refreshInventoryCount: 0
        )
        let relaunched = AppModel(
            ledger: setup.ledger,
            queryService: LifecycleQuery(),
            coordinator: relaunchedCoordinator,
            pricingInbox: LifecycleInbox(failure: false, failureIsOneShot: false),
            grantStore: SourceGrantStore(
                defaults: setup.defaults,
                bookmarkAccess: setup.access
            ),
            preferences: setup.preferences,
            bundledCatalogData: try bundledCatalogData(),
            applicationPaths: ApplicationPaths(
                root: URL(fileURLWithPath: "/tmp/relaunch-support", isDirectory: true)
            ),
            now: { Date(timeIntervalSince1970: 1_775_000_000) },
            calendar: Calendar(identifier: .gregorian),
            discovery: LifecycleDiscovery(failingRoot: nil, blockingGate: nil),
            sourcePicker: LifecycleSourcePicker(url: nil)
        )

        await relaunched.start()

        let relaunchedCounts = await relaunchedCoordinator.counts()
        let relaunchedRoots = await relaunchedCoordinator.activeRoots()
        XCTAssertEqual(relaunchedCounts, [1, 0, 0])
        XCTAssertEqual(Set(relaunchedRoots.keys), [.codex])
        XCTAssertEqual(relaunched.state.grantedProviders, [.codex])
        XCTAssertTrue(relaunched.state.onboardingRequired)
        await relaunched.shutdown()
    }

    func testApprovedZeroToOneGrantStartsOneRootRuntime() async throws {
        let source = URL(
            fileURLWithPath: "/tmp/approved-zero-to-one",
            isDirectory: true
        )
        let setup = try makeSetup(
            approved: true,
            grantedProviders: [],
            pickedSource: source
        )
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.chooseSource(.claudeCode)

        let counts = await setup.coordinator.counts()
        let roots = await setup.coordinator.activeRoots()
        XCTAssertEqual(counts, [1, 0, 0])
        XCTAssertEqual(roots[.claudeCode]?.path, source.standardizedFileURL.path)
        XCTAssertTrue(setup.model.state.onboardingRequired)
    }

    func testApprovedIncompletePairCompletionPublishesBothGrantsAndClearsOnboarding() async throws {
        let source = URL(
            fileURLWithPath: "/tmp/replacement-complete-codex",
            isDirectory: true
        )
        let setup = try makeSetup(
            approved: true,
            grantedProviders: [.claudeCode],
            pickedSource: source
        )
        defer { setup.cleanup() }
        await setup.model.start()

        await setup.model.chooseSource(.codex)

        XCTAssertEqual(setup.model.state.grantedProviders, Set(Provider.allCases))
        XCTAssertFalse(setup.model.state.onboardingRequired)
        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.codex"), Data([9]))
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts, [2, 0, 1])
        let roots = await setup.coordinator.activeRoots()
        XCTAssertEqual(Set(roots.keys), Set(Provider.allCases))
    }

    func testFailedApprovedIncompletePairReplacementRestoresOneRootRuntime() async throws {
        let source = URL(
            fileURLWithPath: "/tmp/replacement-incomplete-restart-failure",
            isDirectory: true
        )
        let setup = try makeSetup(
            approved: true,
            grantedProviders: [.claudeCode],
            pickedSource: source,
            coordinatorFailingStartRoot: source
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorState = setup.model.state

        await setup.model.chooseSource(.codex)

        XCTAssertEqual(setup.model.state, priorState)
        XCTAssertNil(setup.defaults.data(forKey: "sourceBookmark.codex"))
        XCTAssertFalse(setup.model.hasActiveGrant(for: .codex))
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts[0], 3)
        let roots = await setup.coordinator.activeRoots()
        XCTAssertEqual(Set(roots.keys), [.claudeCode])
    }

    func testFailedReplacementRestartRestoresOldBookmarkGrantAndRuntime() async throws {
        let dates = IncrementingNow()
        let replacement = URL(
            fileURLWithPath: "/tmp/replacement-restart-failure",
            isDirectory: true
        )
        let setup = try makeSetup(
            approved: true,
            pickedSource: replacement,
            coordinatorFailingStartRoot: replacement,
            restoredInventoryCount: 7,
            now: { dates() }
        )
        defer { setup.cleanup() }
        await setup.model.start()
        let priorUpdate = setup.model.state.lastUpdated
        let priorBookmark = setup.defaults.data(forKey: "sourceBookmark.claude_code")

        await setup.model.chooseSource(.claudeCode)

        XCTAssertEqual(setup.defaults.data(forKey: "sourceBookmark.claude_code"), priorBookmark)
        XCTAssertEqual(setup.access.counts, [3, 1])
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 7)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.codex], 7)
        XCTAssertNotEqual(setup.model.state.lastUpdated, priorUpdate)
        guard case let .healthy(fileCount, _) = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("restored inventory did not publish healthy state")
        }
        XCTAssertEqual(fileCount, 7)
        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts[0], 3)
        let restoredRoots = await setup.coordinator.activeRoots()
        XCTAssertFalse(restoredRoots[.claudeCode]?.lastPathComponent.hasPrefix("replacement-") == true)

        let calls = await setup.query.calls()
        let runID = await setup.coordinator.runID()
        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .attention(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await setup.query.waitForCompletedCallCount(calls + 1)
        await waitUntil {
            if case .warning = setup.model.state.sourceHealth[.claudeCode] { return true }
            return false
        }
        guard case .warning = setup.model.state.sourceHealth[.claudeCode] else {
            return XCTFail("restored runtime did not process a later event")
        }
    }

    func testShutdownOverlappingReplacementRestartKeepsNewGrantUntilStopCompletes() async throws {
        let replacement = URL(
            fileURLWithPath: "/tmp/replacement-overlap-shutdown",
            isDirectory: true
        )
        let startGate = AsyncTestGate()
        let stopGate = AsyncTestGate()
        let recorder = ReplacementRecorder()
        let setup = try makeSetup(
            approved: true,
            coordinatorStartGate: startGate,
            coordinatorStartGateCall: 2,
            coordinatorStopGate: stopGate,
            coordinatorStopGateCall: 2,
            pickedSource: replacement,
            replacementRecorder: recorder
        )
        defer { setup.cleanup() }
        await setup.model.start()
        recorder.reset()

        let replacementFinished = AsyncFlag()
        let replacementTask = Task {
            await setup.model.chooseSource(.claudeCode)
            await replacementFinished.set()
        }
        await startGate.waitUntilEntered()
        let shutdownTask = Task { await setup.model.shutdown() }
        await stopGate.waitUntilEntered()

        await startGate.resume()
        _ = await replacementFinished.wait(for: .milliseconds(50))
        XCTAssertEqual(setup.access.counts[1], 0)
        XCTAssertFalse(recorder.snapshot.contains("grant.stop.claude_code"))

        await stopGate.resume()
        await replacementTask.value
        _ = await shutdownTask.value

        let events = recorder.snapshot
        guard let stopComplete = events.firstIndex(of: "coordinator.stop.complete"),
              let firstGrantClose = events.firstIndex(where: { $0.hasPrefix("grant.stop.") }) else {
            return XCTFail("missing replacement shutdown events: \(events)")
        }
        XCTAssertTrue(stopComplete < firstGrantClose)
    }

    func testRecoveryMarkerTriggersOneOrderedInventoryRefresh() async throws {
        let setup = try makeSetup(approved: false, refreshInventoryCount: 9)
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let baselineCalls = await setup.query.calls()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            requiresInventoryRefresh: true,
            providers: [:]
        ))
        await setup.query.waitForCompletedCallCount(baselineCalls + 1)
        await waitUntil {
            setup.model.state.sourceFileCounts[.claudeCode] == 9
        }

        let counts = await setup.coordinator.counts()
        XCTAssertEqual(counts[1], 1)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.claudeCode], 9)
        XCTAssertEqual(setup.model.state.sourceFileCounts[.codex], 9)
    }

    func testRetryPreservesLatestCatalogPrerequisiteSemantics() async throws {
        for failure in [StartupFailurePoint.latestCatalog] {
            let setup = try makeSetup(
                approved: false,
                failure: failure,
                failureIsOneShot: true,
                catalogAlreadyApplied: true
            )
            defer { setup.cleanup() }
            await setup.model.start()
            guard case .failed = setup.model.state.lifecycle else {
                return XCTFail("expected \(failure) to fail once")
            }

            await setup.model.refresh()

            XCTAssertEqual(setup.model.state.lifecycle, .ready)
            let applyCount = await setup.ledger.appliedCount()
            let inboxCounts = await setup.inbox.counts()
            XCTAssertEqual(applyCount, 0)
            XCTAssertEqual(inboxCounts, [1, 0])
        }
    }

    func testPersistedProviderDiagnosticsRemainWarningsAfterStartup() async throws {
        let setup = try makeSetup(
            approved: false,
            durableSkipped: [.claudeCode: 2]
        )
        defer { setup.cleanup() }

        await setup.model.start()

        XCTAssertEqual(setup.model.health.skippedRecordCount, 2)
        XCTAssertTrue(setup.model.health.hasWarning)
        XCTAssertEqual(
            setup.model.sourceHealth[.claudeCode],
            .warning(message: TokenboardHealth.Issue.unknownFormats.message)
        )
    }

    func testBatchDiagnosticsAwaitMergesIntoCurrentState() async throws {
        let diagnosticsGate = AsyncTestGate()
        let setup = try makeSetup(
            approved: false,
            skippedCountGateCall: 3,
            skippedCountGate: diagnosticsGate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.startHistoricalImport()
        let runID = await setup.coordinator.runID()

        await setup.coordinator.emit(IngestionBatchResult(
            runID: runID,
            sequence: 2,
            scope: .incremental,
            providers: [.claudeCode: .success(discoveredFiles: 1, scannedFiles: 1)]
        ))
        await diagnosticsGate.waitUntilEntered()
        await setup.model.select(displayMetric: .apiValue)
        var recoveryState = setup.model.state
        recoveryState.health = recoveryState.health.replacing(
            database: .recoveryRequired(message: "newer health")
        )
        setup.model.commitState(recoveryState)
        await diagnosticsGate.resume()
        await waitUntil { setup.model.lastAppliedSequence[runID] == 2 }

        XCTAssertEqual(setup.model.state.selectedDisplayMetric, .apiValue)
        XCTAssertEqual(
            setup.model.health.database,
            .recoveryRequired(message: "newer health")
        )
    }

    func testReplacementDiscoveryDoesNotBlockMainActor() async throws {
        let replacement = URL(
            fileURLWithPath: "/tmp/replacement-off-main-discovery",
            isDirectory: true
        )
        let discoveryGate = BlockingDiscoveryGate()
        let setup = try makeSetup(
            approved: false,
            pickedSource: replacement,
            discoveryGate: discoveryGate
        )
        defer { setup.cleanup() }
        await setup.model.start()

        let replacementTask = Task { await setup.model.chooseSource(.claudeCode) }
        await discoveryGate.waitUntilEntered()
        let selectionFinished = AsyncFlag()
        let selection = Task {
            await setup.model.select(displayMetric: .apiValue)
            await selectionFinished.set()
        }
        let selectedOffMain = await selectionFinished.wait(for: .milliseconds(75))

        discoveryGate.resume()
        await selection.value
        await replacementTask.value
        XCTAssertTrue(selectedOffMain)
        XCTAssertEqual(setup.model.state.selectedDisplayMetric, .apiValue)
    }

    func testRetryCleansUpOneShotCatalogAndInboxFailures() async throws {
        let catalog = try makeSetup(
            approved: false,
            failure: .applyCatalog,
            failureIsOneShot: true,
            catalogCommitBeforeFailure: true
        )
        defer { catalog.cleanup() }
        await catalog.model.start()
        await catalog.model.refresh()
        XCTAssertEqual(catalog.model.state.lifecycle, .ready)
        let applyCount = await catalog.ledger.appliedCount()
        XCTAssertEqual(applyCount, 1)

        let inbox = try makeSetup(
            approved: false,
            failure: .inbox,
            failureIsOneShot: true
        )
        defer { inbox.cleanup() }
        await inbox.model.start()
        let failedInboxCounts = await inbox.inbox.counts()
        XCTAssertEqual(failedInboxCounts, [1, 1])
        await inbox.model.refresh()
        XCTAssertEqual(inbox.model.state.lifecycle, .ready)
        let recoveredInboxCounts = await inbox.inbox.counts()
        XCTAssertEqual(recoveredInboxCounts, [2, 1])
    }

    private func makeSetup(
        approved: Bool,
        grantedProviders: Set<Provider> = Set(Provider.allCases),
        failure: StartupFailurePoint? = nil,
        failureIsOneShot: Bool = false,
        catalogAlreadyApplied: Bool = false,
        startupGate: AsyncTestGate? = nil,
        coordinatorStartGate: AsyncTestGate? = nil,
        coordinatorStartGateCall: Int = 1,
        coordinatorRefreshGate: AsyncTestGate? = nil,
        coordinatorStopGate: AsyncTestGate? = nil,
        coordinatorStopGateCall: Int = 1,
        pickedSource: URL? = nil,
        discoveryFailureRoot: URL? = nil,
        discoveryGate: BlockingDiscoveryGate? = nil,
        replacementRecorder: ReplacementRecorder? = nil,
        coordinatorFailingStartRoot: URL? = nil,
        restoredInventoryCount: Int? = nil,
        refreshInventoryCount: Int = 0,
        durableSkipped: [Provider: Int] = [:],
        skippedCountGateCall: Int? = nil,
        skippedCountGate: AsyncTestGate? = nil,
        catalogCommitBeforeFailure: Bool = false,
        now: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_775_000_000) }
    ) throws -> LifecycleSetup {
        let suite = "AppModelLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let preferences = AppPreferences(defaults: defaults)
        preferences.historicalImportApproved = approved
        let access = LifecycleBookmarkAccess(recorder: replacementRecorder)
        for provider in grantedProviders {
            let marker = provider == .claudeCode ? Data([1]) : Data([2])
            let root = URL(fileURLWithPath: "/tmp/\(suite)-\(provider.rawValue)", isDirectory: true)
            defaults.set(marker, forKey: "sourceBookmark.\(provider.rawValue)")
            access.roots[marker] = root
        }
        let ledger = LifecycleLedger(
            failure: failure,
            failureIsOneShot: failureIsOneShot,
            catalogAlreadyApplied: catalogAlreadyApplied,
            catalogCommitBeforeFailure: catalogCommitBeforeFailure,
            startupGate: startupGate,
            durableSkipped: durableSkipped,
            skippedCountGateCall: skippedCountGateCall,
            skippedCountGate: skippedCountGate
        )
        let inbox = LifecycleInbox(
            failure: failure == .inbox,
            failureIsOneShot: failureIsOneShot
        )
        let coordinator = LifecycleCoordinator(
            startGate: coordinatorStartGate,
            startGateCall: coordinatorStartGateCall,
            refreshGate: coordinatorRefreshGate,
            stopGate: coordinatorStopGate,
            stopGateCall: coordinatorStopGateCall,
            failingStartRoot: coordinatorFailingStartRoot,
            recorder: replacementRecorder,
            restoredInventoryCount: restoredInventoryCount,
            refreshInventoryCount: refreshInventoryCount
        )
        let query = LifecycleQuery()
        let store = SourceGrantStore(defaults: defaults, bookmarkAccess: access)
        let model = AppModel(
            ledger: ledger,
            queryService: query,
            coordinator: coordinator,
            pricingInbox: inbox,
            grantStore: store,
            preferences: preferences,
            bundledCatalogData: try bundledCatalogData(),
            applicationPaths: ApplicationPaths(
                root: URL(fileURLWithPath: "/tmp/\(suite)-support", isDirectory: true)
            ),
            now: now,
            calendar: Calendar(identifier: .gregorian),
            discovery: LifecycleDiscovery(
                failingRoot: discoveryFailureRoot,
                blockingGate: discoveryGate
            ),
            sourcePicker: LifecycleSourcePicker(url: pickedSource)
        )
        return LifecycleSetup(
            model: model,
            ledger: ledger,
            inbox: inbox,
            coordinator: coordinator,
            query: query,
            access: access,
            preferences: preferences,
            defaults: defaults,
            cleanup: { defaults.removePersistentDomain(forName: suite) }
        )
    }

    private func bundledCatalogData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Resources/tokenboard-pricing.json"))
    }

    private func waitUntil(_ condition: @escaping @MainActor () async -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while clock.now < deadline {
            if await condition() { return }
            try? await clock.sleep(for: .milliseconds(1))
        }
        XCTFail("condition was not met")
    }
}

private enum StartupFailurePoint: CaseIterable, Sendable {
    case migrate
    case integrity
    case latestCatalog
    case applyCatalog
    case inbox
}

private enum LifecycleFailure: Error {
    case injected
}

private struct LifecycleSetup {
    let model: AppModel
    let ledger: LifecycleLedger
    let inbox: LifecycleInbox
    let coordinator: LifecycleCoordinator
    let query: LifecycleQuery
    let access: LifecycleBookmarkAccess
    let preferences: AppPreferences
    let defaults: UserDefaults
    let cleanup: () -> Void
}

private actor AsyncTestGate {
    private var entered = false
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() async {
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func resume() {
        let suspended = continuations
        continuations.removeAll()
        suspended.forEach { $0.resume() }
    }
}

private actor AsyncFlag {
    private var current = false
    func set() { current = true }
    func value() -> Bool { current }

    func wait(for duration: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        while !current, clock.now < deadline {
            try? await clock.sleep(for: .milliseconds(1))
        }
        return current
    }
}

private actor LifecycleLedger: AppLedgerRuntime {
    private var failure: StartupFailurePoint?
    private let failureIsOneShot: Bool
    private let catalogAlreadyApplied: Bool
    private let catalogCommitBeforeFailure: Bool
    private let startupGate: AsyncTestGate?
    private(set) var applyCount = 0
    private var appliedCatalog: Data?
    private var shutdowns = 0
    private var migrations = 0
    private let durableSkipped: [Provider: Int]
    private let skippedCountGateCall: Int?
    private let skippedCountGate: AsyncTestGate?
    private var skippedCountCalls = 0

    init(
        failure: StartupFailurePoint?,
        failureIsOneShot: Bool,
        catalogAlreadyApplied: Bool,
        catalogCommitBeforeFailure: Bool,
        startupGate: AsyncTestGate?,
        durableSkipped: [Provider: Int],
        skippedCountGateCall: Int?,
        skippedCountGate: AsyncTestGate?
    ) {
        self.failure = failure
        self.failureIsOneShot = failureIsOneShot
        self.catalogAlreadyApplied = catalogAlreadyApplied
        self.catalogCommitBeforeFailure = catalogCommitBeforeFailure
        self.startupGate = startupGate
        self.durableSkipped = durableSkipped
        self.skippedCountGateCall = skippedCountGateCall
        self.skippedCountGate = skippedCountGate
        appliedCatalog = catalogAlreadyApplied ? Data([1]) : nil
    }

    func migrate() async throws {
        migrations += 1
        if let startupGate { await startupGate.suspend() }
        try failIfNeeded(.migrate)
    }
    func integrityCheck() throws { try failIfNeeded(.integrity) }
    func latestAppliedPricingCatalogJSON() throws -> Data? {
        try failIfNeeded(.latestCatalog)
        return appliedCatalog
    }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) throws {
        if failure == .applyCatalog, !catalogCommitBeforeFailure {
            try failIfNeeded(.applyCatalog)
        }
        applyCount += 1
        appliedCatalog = canonicalJSON
        if failure == .applyCatalog, catalogCommitBeforeFailure {
            if failureIsOneShot { failure = nil }
            throw LifecycleFailure.injected
        }
        try failIfNeeded(.applyCatalog)
    }
    func pricingSnapshot() -> PricingSnapshot {
        PricingSnapshot(catalogIDs: [], rates: [], aliases: [])
    }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { [] }
    func skippedRecordCount() async -> Int {
        skippedCountCalls += 1
        if skippedCountCalls == skippedCountGateCall, let skippedCountGate {
            await skippedCountGate.suspend()
        }
        return durableSkipped.values.reduce(0, +)
    }
    func skippedRecordCountsByProvider() -> [Provider: Int] { durableSkipped }
    func shutdown() { shutdowns += 1 }

    private func failIfNeeded(_ point: StartupFailurePoint) throws {
        guard failure == point else { return }
        if failureIsOneShot { failure = nil }
        throw LifecycleFailure.injected
    }

    func appliedCount() -> Int { applyCount }
    func shutdownCount() -> Int { shutdowns }
    func migrateCount() -> Int { migrations }
}

private actor LifecycleInbox: AppPricingInboxWatching {
    private var failure: Bool
    private let failureIsOneShot: Bool
    private var starts = 0
    private var stops = 0
    init(failure: Bool, failureIsOneShot: Bool) {
        self.failure = failure
        self.failureIsOneShot = failureIsOneShot
    }
    func start() throws {
        starts += 1
        if failure {
            if failureIsOneShot { failure = false }
            throw LifecycleFailure.injected
        }
    }
    func stop() { stops += 1 }
    func pendingCandidate() -> PendingPricingCandidate? { nil }
    func exportCurrentSnapshot() {}
    func applyPending() {}
    func rejectPending() {}
    func counts() -> [Int] { [starts, stops] }
}

private actor LifecycleCoordinator: AppIngestionCoordinating {
    private let startGate: AsyncTestGate?
    private let startGateCall: Int
    private let refreshGate: AsyncTestGate?
    private let stopGate: AsyncTestGate?
    private let stopGateCall: Int
    private let failingStartRoot: URL?
    private let recorder: ReplacementRecorder?
    private let restoredInventoryCount: Int?
    private let refreshInventoryCount: Int
    private var resultContinuation: AsyncStream<IngestionBatchResult>.Continuation?
    private var starts = 0
    private var refreshes = 0
    private var stops = 0
    private(set) var currentRunID: UInt64 = 0
    private var currentSequence: UInt64 = 0
    private var roots: [Provider: URL] = [:]
    private var stopBarrierOpen = false
    private var shouldFailReplacementStart = true
    private var refreshWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var stopWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var startWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    init(
        startGate: AsyncTestGate?,
        startGateCall: Int,
        refreshGate: AsyncTestGate?,
        stopGate: AsyncTestGate?,
        stopGateCall: Int,
        failingStartRoot: URL?,
        recorder: ReplacementRecorder?,
        restoredInventoryCount: Int?,
        refreshInventoryCount: Int
    ) {
        self.startGate = startGate
        self.startGateCall = startGateCall
        self.refreshGate = refreshGate
        self.stopGate = stopGate
        self.stopGateCall = stopGateCall
        self.failingStartRoot = failingStartRoot
        self.recorder = recorder
        self.restoredInventoryCount = restoredInventoryCount
        self.refreshInventoryCount = refreshInventoryCount
    }

    func results() -> AsyncStream<IngestionBatchResult> {
        AsyncStream { continuation in resultContinuation = continuation }
    }
    func start(roots: [Provider: URL]) async throws -> IngestionBatchResult {
        starts += 1
        resumeCountWaiters(&startWaiters, count: starts)
        currentRunID += 1
        currentSequence = 0
        self.roots = roots
        if shouldFailReplacementStart,
           let failingStartRoot,
           roots.values.contains(where: {
               $0.lastPathComponent == failingStartRoot.lastPathComponent
           }) {
            shouldFailReplacementStart = false
            throw LifecycleFailure.injected
        }
        let inventoryCount = starts >= 3 ? restoredInventoryCount : nil
        let result = successResult(scope: .inventory, discoveredOverride: inventoryCount)
        if let startGate, starts == startGateCall { await startGate.suspend() }
        return result
    }
    func startMonitoring(roots: [Provider: URL]) async throws -> IngestionBatchResult {
        try await start(roots: roots)
    }
    func refreshAll() async -> IngestionBatchResult {
        refreshes += 1
        resumeCountWaiters(&refreshWaiters, count: refreshes)
        let result = successResult(
            scope: .inventory,
            discoveredOverride: refreshInventoryCount
        )
        if let refreshGate, refreshes == 1 { await refreshGate.suspend() }
        return result
    }
    func replaceSource(
        _ provider: Provider,
        with root: URL,
        roots: [Provider: URL]
    ) async throws -> IngestionBatchResult {
        await stop()
        return try await start(roots: roots)
    }
    func revokeSource(
        _ provider: Provider,
        remainingRoots: [Provider: URL]
    ) async -> UInt64? {
        await stop()
        roots = remainingRoots
        guard !remainingRoots.isEmpty else { return nil }
        currentRunID += 1
        currentSequence = 0
        return currentRunID
    }
    func stop() async {
        stops += 1
        resumeCountWaiters(&stopWaiters, count: stops)
        recorder?.append("coordinator.stop")
        recorder?.append("coordinator.stop.begin")
        if let stopGate, stops == stopGateCall || stopBarrierOpen {
            stopBarrierOpen = true
            await stopGate.suspend()
            stopBarrierOpen = false
        }
        recorder?.append("coordinator.stop.complete")
    }
    func counts() -> [Int] { [starts, refreshes, stops] }
    func runID() -> UInt64 { currentRunID }
    func activeRoots() -> [Provider: URL] { roots }
    func emit(_ result: IngestionBatchResult) {
        if result.runID == currentRunID {
            currentSequence = max(currentSequence, result.sequence)
        }
        resultContinuation?.yield(result)
    }

    func waitForRefreshCount(_ expected: Int) async {
        guard refreshes < expected else { return }
        await withCheckedContinuation { refreshWaiters.append((expected, $0)) }
    }

    func waitForStopCount(_ expected: Int) async {
        guard stops < expected else { return }
        await withCheckedContinuation { stopWaiters.append((expected, $0)) }
    }

    func waitForStartCount(_ expected: Int) async {
        guard starts < expected else { return }
        await withCheckedContinuation { startWaiters.append((expected, $0)) }
    }

    private func successResult(
        scope: IngestionBatchScope,
        discoveredOverride: Int? = nil
    ) -> IngestionBatchResult {
        currentSequence += 1
        return IngestionBatchResult(
            runID: currentRunID,
            sequence: currentSequence,
            scope: scope,
            providers: Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
                let discovered = discoveredOverride
                    ?? (roots[provider]?.lastPathComponent.hasPrefix("replacement-") == true ? 2 : 0)
                return (provider, .success(discoveredFiles: discovered, scannedFiles: 0))
            })
        )
    }

    private func resumeCountWaiters(
        _ waiters: inout [(Int, CheckedContinuation<Void, Never>)],
        count: Int
    ) {
        let ready = waiters.filter { $0.0 <= count }
        waiters.removeAll { $0.0 <= count }
        ready.forEach { $0.1.resume() }
    }
}

private actor LifecycleQuery: AppUsageQuerying {
    private var heldPeriods: Set<CalendarPeriod> = []
    private var continuations: [CalendarPeriod: CheckedContinuation<Void, Never>] = [:]
    private var pendingWaiters: [CalendarPeriod: [CheckedContinuation<Void, Never>]] = [:]
    private var callWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var completedCallWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var callCount = 0
    private var completedCallCount = 0

    func hold(periods: Set<CalendarPeriod>) { heldPeriods = periods }
    func summary(period: CalendarPeriod, now: Date, calendar: Calendar) async -> UsageSummary {
        callCount += 1
        let readyCallWaiters = callWaiters.filter { $0.0 <= callCount }
        callWaiters.removeAll { $0.0 <= callCount }
        readyCallWaiters.forEach { $0.1.resume() }
        if heldPeriods.contains(period) {
            await withCheckedContinuation {
                continuations[period] = $0
                let waiters = pendingWaiters.removeValue(forKey: period) ?? []
                waiters.forEach { $0.resume() }
            }
        }
        let total: Int64 = switch period {
        case .thisWeek: 2_000
        case .thisMonth: 3_000
        default: 1_000
        }
        let summary = UsageSummary(
            period: period,
            tokenTotal: total,
            knownAPIEquivalentUSD: 0,
            unpricedTokens: 0
        )
        completedCallCount += 1
        let completed = completedCallWaiters.filter { $0.0 <= completedCallCount }
        completedCallWaiters.removeAll { $0.0 <= completedCallCount }
        completed.forEach { $0.1.resume() }
        return summary
    }
    func waitUntilPending(_ period: CalendarPeriod) async {
        guard continuations[period] == nil else { return }
        await withCheckedContinuation { pendingWaiters[period, default: []].append($0) }
    }
    func resume(_ period: CalendarPeriod) {
        heldPeriods.remove(period)
        continuations.removeValue(forKey: period)?.resume()
    }

    func calls() -> Int { callCount }

    func waitForCallCount(_ expected: Int) async {
        guard callCount < expected else { return }
        await withCheckedContinuation { callWaiters.append((expected, $0)) }
    }

    func waitForCompletedCallCount(_ expected: Int) async {
        guard completedCallCount < expected else { return }
        await withCheckedContinuation { completedCallWaiters.append((expected, $0)) }
    }
}

private struct LifecycleDiscovery: LogDiscovering {
    let failingRoot: URL?
    let blockingGate: BlockingDiscoveryGate?

    func jsonlFiles(under root: URL) throws -> [URL] {
        if let failingRoot,
           root.lastPathComponent == failingRoot.lastPathComponent {
            throw LifecycleFailure.injected
        }
        if root.lastPathComponent.hasPrefix("replacement-"), let blockingGate {
            blockingGate.suspend()
        }
        if root.lastPathComponent.hasPrefix("replacement-") {
            return [root.appending(path: "one.jsonl"), root.appending(path: "two.jsonl")]
        }
        return []
    }
}

private final class BlockingDiscoveryGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var entered = false
    private var released = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func suspend() {
        condition.lock()
        entered = true
        let waiters = enteredWaiters
        enteredWaiters.removeAll()
        waiters.forEach { $0.resume() }
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if entered {
                condition.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class LifecycleBookmarkAccess: SecurityScopedBookmarkAccessing, @unchecked Sendable {
    private let recorder: ReplacementRecorder?
    var roots: [Data: URL] = [:]
    private var starts = 0
    private var stops = 0
    var counts: [Int] { [starts, stops] }

    init(recorder: ReplacementRecorder?) { self.recorder = recorder }

    func makeBookmark(for url: URL, options: URL.BookmarkCreationOptions) -> Data { Data([9]) }
    func resolveBookmark(
        _ data: Data,
        options: URL.BookmarkResolutionOptions
    ) throws -> ResolvedSourceBookmark {
        ResolvedSourceBookmark(url: roots[data]!, isStale: false)
    }
    func startAccessing(_ url: URL) -> Bool { starts += 1; return true }
    func stopAccessing(_ url: URL) {
        stops += 1
        let provider = url.lastPathComponent.hasSuffix(Provider.claudeCode.rawValue)
            ? Provider.claudeCode
            : Provider.codex
        recorder?.append("grant.stop.\(provider.rawValue)")
    }
}

@MainActor
private struct LifecycleSourcePicker: AppSourcePicking {
    let url: URL?
    func select(provider: Provider) throws -> URL? { url }
}

private final class ReplacementRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var snapshot: [String] { lock.withLock { events } }
    func append(_ event: String) { lock.withLock { events.append(event) } }
    func reset() { lock.withLock { events.removeAll() } }
}

private final class IncrementingNow: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: TimeInterval = 1_775_000_000

    func callAsFunction() -> Date {
        lock.withLock {
            defer { tick += 1 }
            return Date(timeIntervalSince1970: tick)
        }
    }
}
