import AppKit
import Foundation
import XCTest
@testable import TokenboardApp
import TokenboardCore

@MainActor
final class SettingsTests: XCTestCase {
    func testSettingsUsesFourFocusedTabsInStableOrder() {
        XCTAssertEqual(
            SettingsNavigationPresentation.sections.map(\.title),
            ["General", "Sources", "Pricing", "Diagnostics"]
        )
        XCTAssertEqual(
            SettingsNavigationPresentation.sections.map(\.systemImage),
            ["gearshape", "folder", "dollarsign.circle", "wrench.and.screwdriver"]
        )
    }

    func testGeneralSettingsUsesTheExistingMenuBarChoicesInStableOrder() {
        XCTAssertEqual(
            UsageSelectionPresentation.displayMetrics.map(
                UsageSelectionPresentation.displayMetricTitle
            ),
            ["Tokens", "API Value"]
        )
        XCTAssertEqual(
            UsageSelectionPresentation.periods.map(
                UsageSelectionPresentation.periodTitle
            ),
            ["Today", "This Week", "This Month", "This Year", "All Time"]
        )
        XCTAssertEqual(
            UsageSelectionPresentation.currencies.map(\.rawValue),
            ["USD", "EUR", "JPY", "GBP", "CNY"]
        )
    }

    func testDiagnosticsCollectsCurrentSourceIssuesBehindTechnicalDetails() {
        let health = TokenboardHealth(
            claude: .warning(issue: .truncatedLog, message: "Imported log was truncated"),
            codex: .notGranted,
            database: .healthy,
            lastSuccessfulScan: nil,
            skippedRecordCount: 0,
            unpricedTokens: 0
        )

        XCTAssertEqual(SettingsDiagnosticIssue.current(in: health), [
            SettingsDiagnosticIssue(provider: .claudeCode, message: "Imported log was truncated"),
            SettingsDiagnosticIssue(provider: .codex, message: "Access required")
        ])
        XCTAssertEqual(SettingsCopy.technicalDetails, "Technical details")
    }

    func testRoutineSourceSettingsHideIssueCopy() {
        XCTAssertNil(SourceSettingsPresentation.status(
            for: .warning(issue: .truncatedLog, message: "Imported log was truncated")
        ))
        XCTAssertEqual(
            SourceSettingsPresentation.status(for: .indexing(fileCount: 3)),
            "Ready to scan 3 logs"
        )
    }

    func testPricingUpdateCopyExplainsTheNetworkBoundaryAndNextStep() {
        XCTAssertEqual(
            PricingUpdateCopy.explanation,
            "Tokenboard has no network access. Paste this prompt into Claude Code or Codex; the agent researches pricing, reports its sources, and safely replaces the local catalog. Valid changes apply automatically."
        )
        XCTAssertEqual(PricingUpdateCopy.buttonTitle, "Copy Pricing Update Prompt")
        XCTAssertEqual(
            PricingUpdateCopy.status(.current(catalogID: "current"), activeCatalogID: "current"),
            "Active catalog · current"
        )
        XCTAssertEqual(
            PricingUpdateCopy.status(.invalid(.invalidCatalog), activeCatalogID: "current"),
            "Last update failed · Keeping current"
        )
    }

    func testPricingOverviewKeepsOnlyEssentialCatalogMetadata() {
        XCTAssertEqual(
            PricingOverviewCopy.visibleLabels,
            ["Display currency", "Unpriced usage", "Model pricing", "Exchange rates"]
        )
        XCTAssertFalse(PricingOverviewCopy.visibleLabels.contains("Official provenance"))
    }

    func testPricingPresentationGroupsProvidersAndSortsModelIdentifiers() {
        let models = [
            ActiveModelPricingSummary(
                provider: .codex,
                canonicalModelID: "gpt-z",
                rates: [.output: 30]
            ),
            ActiveModelPricingSummary(
                provider: .claudeCode,
                canonicalModelID: "claude-b",
                rates: [.inputUncached: 5]
            ),
            ActiveModelPricingSummary(
                provider: .codex,
                canonicalModelID: "gpt-a",
                rates: [.inputUncached: 2]
            )
        ]

        XCTAssertEqual(PricingSettingsPresentation.groups(for: models), [
            PricingProviderGroup(provider: .claudeCode, models: [models[1]]),
            PricingProviderGroup(provider: .codex, models: [models[2], models[0]])
        ])
        XCTAssertEqual(
            PricingOverviewCopy.modelPricingHint,
            "USD per million tokens. All current catalog rates are shown."
        )
        let claudeMetrics: [UsageMetric] = [.inputUncached]
        XCTAssertEqual(
            PricingSettingsPresentation.metrics(for: PricingProviderGroup(
                provider: .claudeCode,
                models: [models[1]]
            )),
            claudeMetrics
        )
        let codexMetrics: [UsageMetric] = [.inputUncached, .output]
        XCTAssertEqual(
            PricingSettingsPresentation.metrics(for: PricingProviderGroup(
                provider: .codex,
                models: [models[2], models[0]]
            )),
            codexMetrics
        )
    }

    func testSourcePresentationUsesOneOrderedProviderStack() {
        XCTAssertEqual(
            SourceSettingsPresentation.providerOrder,
            [.claudeCode, .codex]
        )
    }

    func testPricingSummaryShowsActiveModelRatesAndLatestExchangeSnapshot() async throws {
        let exchangeRates = ExchangeRateSnapshot(
            catalogID: "current",
            effectiveDate: "2026-08-07",
            verifiedAt: "2026-08-07",
            provenanceURL: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!,
            rates: [.usd: 1, .eur: Decimal(string: "0.8")!, .jpy: 150, .gbp: Decimal(string: "0.7")!, .cny: 7]
        )
        let pricing = PricingSnapshot(
            catalogIDs: ["current"],
            rates: [
                storedRate(usd: "2", metric: .inputUncached),
                storedRate(usd: "30", metric: .output)
            ],
            aliases: [storedAlias()],
            exchangeRateSnapshots: [exchangeRates]
        )
        let setup = try makeSetup(pricing: pricing)
        defer { setup.cleanup() }

        await setup.model.start()
        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.pricing.activeModels, [
            ActiveModelPricingSummary(
                provider: .codex,
                canonicalModelID: "gpt-preview",
                rates: [.inputUncached: 2, .output: 30]
            )
        ])
        XCTAssertEqual(setup.model.settingsState.pricing.exchangeRates, exchangeRates)
    }

    func testExchangeRatePresentationOmitsUSDAndUsesReadablePrecision() {
        let exchangeRates = ExchangeRateSnapshot(
            catalogID: "current",
            effectiveDate: "2026-08-10",
            verifiedAt: "2026-08-10",
            provenanceURL: URL(string: "https://www.ecb.europa.eu/stats/eurofxref/eurofxref-daily.xml")!,
            rates: [
                .usd: 1,
                .eur: Decimal(string: "0.865426222")!,
                .jpy: Decimal(string: "158.641280831")!,
                .gbp: Decimal(string: "0.740501947")!,
                .cny: Decimal(string: "6.744353094")!
            ]
        )

        let rows = PricingSettingsPresentation.exchangeRateRows(for: exchangeRates)
        XCTAssertEqual(rows.map(\.currency), [
            DisplayCurrency.eur, .jpy, .gbp, .cny
        ])
        XCTAssertEqual(rows.map(\.formattedRate), [
            "0.8654", "158.64", "0.7405", "6.7444"
        ])
    }

    func testPricingSummaryPublishesModelLevelUnpricedUsageForTheSelectedPeriod() async throws {
        let setup = try makeSetup()
        defer { setup.cleanup() }

        await setup.model.start()
        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.settingsState.pricing.unpricedUsage, [
            UnpricedUsageGroup(
                provider: .codex,
                observedModelID: "gpt-preview",
                canonicalModelID: nil,
                reason: .missingAlias,
                tokenCount: 100_000,
                firstObservedDay: "2026-08-05",
                lastObservedDay: "2026-08-05"
            )
        ])
        XCTAssertEqual(setup.model.settingsState.pricing.coveragePeriod, .today)

        await setup.model.select(period: .thisYear)

        XCTAssertEqual(setup.model.settingsState.pricing.coveragePeriod, .thisYear)
    }

    func testRecoveryLoadsBackupWithoutRestoringUntilExplicitActionAndUsesShutdownBarrier() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let backup = recoveryFiles.backup
        let recovery = SettingsRecovery(backup: backup)
        let setup = try makeSetup(databaseRecovery: recovery)
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
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("newest two") == true)
    }

    func testTerminationGateRejectsRestoreWhileQuiescingAndAfterStopped() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let shutdownGate = SettingsMutationGate()
        let recovery = SettingsRecovery(backup: recoveryFiles.backup)
        let setup = try makeSetup(
            ledgerShutdownGate: shutdownGate,
            databaseRecovery: recovery
        )
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        let termination = Task { await setup.model.shutdown() }
        try await shutdownGate.waitUntilEntered()
        let restoreDuringTermination = Task {
            await setup.model.restoreBackup(recoveryFiles.backup)
        }
        await Task.yield()
        let callsWhileQuiescing = await recovery.restoreCount()
        let mutationsWhileQuiescing = await recovery.mutationCount()
        await shutdownGate.release()
        let terminated = await termination.value
        await restoreDuringTermination.value

        await setup.model.restoreBackup(recoveryFiles.backup)
        let callsAfterStopped = await recovery.restoreCount()
        let mutationsAfterStopped = await recovery.mutationCount()
        guard terminated,
              callsWhileQuiescing == 0,
              mutationsWhileQuiescing == 0,
              callsAfterStopped == 0,
              mutationsAfterStopped == 0,
              setup.model.state.lifecycle == .stopped else {
            throw SettingsError.injected
        }
    }

    func testRestoreUsesTheExactBackupCapturedByConfirmationWhenListChanges() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let captured = recoveryFiles.backup
        let backups = recoveryFiles.root.appending(path: "Backups", directoryHint: .isDirectory)
        let newerURL = backups.appending(path: "ledger-v2-200.sqlite")
        try Data(contentsOf: recoveryFiles.root.appending(path: "ledger.sqlite")).write(to: newerURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 9_999)],
            ofItemAtPath: newerURL.path
        )
        let listing = try await DatabaseRecoveryService(
            databaseURL: recoveryFiles.root.appending(path: "ledger.sqlite"),
            backupDirectory: backups
        ).availableBackups()
        let newer = try XCTUnwrap(listing.first { $0.id != captured.id })
        let recovery = SettingsRecovery(backup: captured)
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await recovery.setAvailable([newer])
        var refreshed = setup.model.settingsState
        refreshed.recoveryBackups = [newer]
        setup.model.commitSettingsState(refreshed)
        await setup.model.restoreBackup(captured)

        let received = await recovery.received()
        XCTAssertEqual(received, [captured])
        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
    }

    func testRestoreDisablesAllConflictingRenderedActionsButShutdownStillAwaitsIt() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let gate = SettingsMutationGate()
        let recovery = SettingsRecovery(backup: recoveryFiles.backup, stageGate: gate)
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()
        var openedPricing = false
        setup.model.onOpenPricing = { openedPricing = true }

        let restore = Task { await setup.model.restoreBackup(recoveryFiles.backup) }
        try await gate.waitUntilEntered()

        XCTAssertEqual(
            DatabaseRecoveryView(model: setup.model).actionState,
            DatabaseRecoveryActionState(canReveal: false, canRestore: false, canQuit: false)
        )
        setup.model.revealLocalData()
        setup.model.openPricing()
        XCTAssertEqual(setup.revealer.selections, [])
        XCTAssertFalse(openedPricing)

        let shutdownCompleted = SettingsCompletionFlag()
        let shutdown = Task {
            _ = await setup.model.shutdown()
            await shutdownCompleted.markCompleted()
        }
        try? await Task.sleep(for: .milliseconds(20))
        let completedEarly = await shutdownCompleted.isCompleted()
        XCTAssertFalse(completedEarly)
        await gate.release()
        await restore.value
        await shutdown.value
        let completed = await shutdownCompleted.isCompleted()
        XCTAssertTrue(completed)
    }

    func testCleanupPendingPublishesCompletedOutcomeAndReenablesQuitAndReveal() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .cleanupPending
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreBackup(recoveryFiles.backup)

        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertFalse(setup.model.settingsState.isRestoringDatabase)
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("completed and verified") == true)
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("artifact was preserved") == true)
        XCTAssertEqual(
            DatabaseRecoveryView(model: setup.model).actionState,
            DatabaseRecoveryActionState(canReveal: true, canRestore: false, canQuit: true)
        )
        setup.model.revealLocalData()
        XCTAssertEqual(setup.revealer.selections, [[setup.paths.root]])
    }

    func testCompletedRestoreRequiresRelaunchAndKeepsSettingsReachable() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(backup: recoveryFiles.backup)
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        var pricingOpenCount = 0
        var settingsOpenCount = 0
        setup.model.onOpenPricing = { pricingOpenCount += 1 }
        setup.model.onOpenSettings = { settingsOpenCount += 1 }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreBackup(recoveryFiles.backup)

        let recoveryActions = DatabaseRecoveryView(model: setup.model).actionState
        guard recoveryActions == DatabaseRecoveryActionState(
            canReveal: true,
            canRestore: false,
            canQuit: true
        ) else { throw SettingsError.injected }
        setup.model.openPricing()
        setup.model.openSettings()
        await setup.model.restoreBackup(recoveryFiles.backup)
        let restores = await recovery.restoreCount()
        guard restores == 1, pricingOpenCount == 0, settingsOpenCount == 1 else {
            throw SettingsError.injected
        }
        setup.model.revealLocalData()
        guard setup.revealer.selections == [[setup.paths.root]] else {
            throw SettingsError.injected
        }
    }

    func testRetryablePreservationFailureRetryTransitionsToVerifiedRelaunchState() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .preservationRetryRequired
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreBackup(recoveryFiles.backup)

        guard DatabaseRecoveryView(model: setup.model).actionState == DatabaseRecoveryActionState(
            canReveal: true,
            canRestore: false,
            canQuit: false,
            canRetryPreservation: true
        ) else { throw SettingsError.injected }

        await setup.model.retryDatabasePreservation()

        let retries = await recovery.preservationRetryCount()
        guard retries == 1,
              setup.model.requiresDatabaseRecoveryRelaunch,
              DatabaseRecoveryView(model: setup.model).actionState == DatabaseRecoveryActionState(
                canReveal: true,
                canRestore: false,
                canQuit: true
              ) else { throw SettingsError.injected }
    }

    func testTerminalPreservationFailureOffersRevealSettingsAndQuitWithoutRetryClaim() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .preservationFailed
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        var settingsOpenCount = 0
        setup.model.onOpenSettings = { settingsOpenCount += 1 }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreBackup(recoveryFiles.backup)

        let actions = DatabaseRecoveryView(model: setup.model).actionState
        guard actions == DatabaseRecoveryActionState(
            canReveal: true,
            canRestore: false,
            canQuit: true,
            canRetryPreservation: false
        ), setup.model.settingsState.statusMessage?.contains("could not be retained") == true else {
            throw SettingsError.injected
        }
        setup.model.openSettings()
        guard settingsOpenCount == 1 else {
            throw SettingsError.injected
        }
        guard await setup.model.shutdown() else { throw SettingsError.injected }
    }

    func testRetryablePreservationBlocksTerminationAndShutdownAwaitsActiveRetry() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let retryGate = SettingsMutationGate()
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .preservationRetryRequired,
            preservationRetryGate: retryGate
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()
        await setup.model.restoreBackup(recoveryFiles.backup)

        guard await setup.model.shutdown() == false else { throw SettingsError.injected }
        let delegate = AppDelegate(model: setup.model)
        guard await delegate.shutdownForTermination() == false else { throw SettingsError.injected }

        let retry = Task { await setup.model.retryDatabasePreservation() }
        try await retryGate.waitUntilEntered()
        let shutdownCompleted = SettingsCompletionFlag()
        let shutdown = Task {
            let result = await setup.model.shutdown()
            await shutdownCompleted.markCompleted()
            return result
        }
        await Task.yield()
        guard await shutdownCompleted.isCompleted() == false else {
            throw SettingsError.injected
        }
        await retryGate.release()
        await retry.value
        guard await shutdown.value,
              setup.model.requiresDatabaseRecoveryRelaunch else {
            throw SettingsError.injected
        }
    }

    func testRetryablePreservationKeepsSettingsReachableAfterWindowClose() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .preservationRetryRequired
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        var settingsOpenCount = 0
        setup.model.onOpenSettings = { settingsOpenCount += 1 }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()
        await setup.model.restoreBackup(recoveryFiles.backup)

        setup.model.openSettings()
        setup.model.openSettings()
        guard settingsOpenCount == 2 else {
            throw SettingsError.injected
        }
    }

    func testOversizedRecoveryBackupPublishesSupportedLimitInsteadOfNoMatch() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            availabilityError: .backupTooLarge(maximumBytes: 256 * 1_024 * 1_024)
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)

        await setup.model.refreshSettings()

        guard setup.model.settingsState.recoveryBackups.isEmpty,
              setup.model.settingsState.statusMessage?.contains("256 MiB") == true else {
            throw SettingsError.injected
        }
    }

    private func makeRecoveryBackup() async throws -> (root: URL, backup: DatabaseBackup) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appending(
            path: "SettingsTests-recovery-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let backups = root.appending(path: "Backups", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: backups, withIntermediateDirectories: true)
        let database = root.appending(path: "ledger.sqlite")
        let connection = try SQLiteConnection(url: database)
        try DatabaseMigrator(
            connection: connection,
            backupDirectory: backups,
            migrations: Migrations.all
        ).migrate(createPreMigrationBackup: false)
        try connection.checkpointWAL()
        try connection.close()
        try Data(contentsOf: database).write(to: backups.appending(path: "ledger-v1-100.sqlite"))
        let service = DatabaseRecoveryService(
            databaseURL: database,
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
        XCTAssertEqual(retryMutations, 0)
        XCTAssertEqual(retryShutdownCount, 1)
        XCTAssertEqual(writerStarts, 0)
        XCTAssertEqual(setup.model.state.lifecycle, .shuttingDown)
    }

    func testRestoreFailureAfterShutdownRequiresRelaunch() async throws {
        let recoveryFiles = try await makeRecoveryBackup()
        defer { try? FileManager.default.removeItem(at: recoveryFiles.root) }
        let recovery = SettingsRecovery(
            backup: recoveryFiles.backup,
            restoreError: .backupChanged
        )
        let setup = try makeSetup(databaseRecovery: recovery)
        defer { setup.cleanup() }
        publishRecoveryRequired(in: setup.model)
        await setup.model.refreshSettings()

        await setup.model.restoreLatestBackup()

        let didAwaitShutdown = await recovery.didAwaitShutdown()
        XCTAssertTrue(didAwaitShutdown)
        XCTAssertEqual(setup.model.state.lifecycle, .stopped)
        XCTAssertTrue(setup.model.requiresDatabaseRecoveryRelaunch)
        XCTAssertTrue(setup.model.settingsState.statusMessage?.contains("Quit and reopen") == true)
    }

    func testTerminationRefusesStrictCloseFailureAndCanRetryWithoutRestartingWriters() async throws {
        let setup = try makeSetup(
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
            let setup = try makeSetup(databaseRecovery: recovery)
            defer { setup.cleanup() }
            publishRecoveryRequired(in: setup.model)
            await setup.model.refreshSettings()

            let restore = Task { await setup.model.restoreLatestBackup() }
            try await gate.waitUntilEntered()
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
        let setup = try makeSetup()
        defer { setup.cleanup() }

        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.state.lifecycle, .ready)
        XCTAssertEqual(setup.model.settingsState.pricing.activeCatalogID, "current")
    }

    func testRefreshingSettingsKeepsTechnicalIssuesOutOfMenuPresentation() async throws {
        let setup = try makeSetup(approved: true)
        defer { setup.cleanup() }
        await setup.model.start()

        XCTAssertEqual(setup.model.health.skippedRecordCount, 3)
        XCTAssertEqual(setup.model.presentation?.statusTitle, "100K")

        await setup.ledger.setSkippedRecordCount(4)
        await setup.model.refreshSettings()

        XCTAssertEqual(setup.model.health.skippedRecordCount, 4)
        XCTAssertEqual(setup.model.presentation?.statusTitle, "100K")
    }

    func testCopyPromptExportsFirstAndWritesOneAutomaticUpdatePrompt() async throws {
        let setup = try makeSetup()
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.model.refreshSettings()
        setup.recorder.reset()

        await setup.model.copyAgentPrompt()

        XCTAssertEqual(setup.recorder.snapshot, ["inbox.export", "pasteboard.replace"])
        XCTAssertEqual(setup.pasteboard.values.count, 1)
        let prompt = try XCTUnwrap(setup.pasteboard.values.first)
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "current-tokenboard-pricing.json").path))
        XCTAssertTrue(prompt.contains(setup.paths.pricing.appending(path: "current-tokenboard-pricing.json.tmp").path))
        XCTAssertFalse(prompt.contains("Pricing/Inbox"))
        XCTAssertFalse(prompt.contains("review the candidate"))
        XCTAssertTrue(prompt.contains("codex / gpt-preview"))
        XCTAssertEqual(setup.model.settingsState.statusMessage, "Prompt copied · Tokenboard made no network request")
    }

    func testChangeReconfiguresOnlyTheSelectedProvider() async throws {
        let replacement = FileManager.default.temporaryDirectory
            .appending(path: "SettingsTests-replacement-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
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
        let replacement = FileManager.default.temporaryDirectory.appending(
            path: "SettingsTests-change-wins-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: replacement) }
        let setup = try makeSetup(
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: replacement,
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let change = Task { await setup.model.changeSource(.claudeCode) }
        try await gate.waitUntilEntered()
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
            grantedProviders: Set(Provider.allCases),
            approved: true,
            pickerURL: URL(fileURLWithPath: "/private/tmp/change-loses", isDirectory: true),
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let revoke = Task { await setup.model.revokeSource(.claudeCode) }
        try await gate.waitUntilEntered()
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
            grantedProviders: Set(Provider.allCases),
            approved: true,
            coordinatorMutationGate: gate
        )
        defer { setup.cleanup() }
        await setup.model.start()
        await setup.coordinator.resetEvidence()

        let first = Task { await setup.model.revokeSource(.claudeCode) }
        try await gate.waitUntilEntered()
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
        let setup = try makeSetup()
        defer { setup.cleanup() }

        setup.model.revealLocalData()

        XCTAssertEqual(setup.revealer.selections, [[setup.paths.root]])
    }

    func testSettingsWindowCreatesAndReleasesSwiftUIViewStateOnDemand() async throws {
        let setup = try makeSetup()
        defer { setup.cleanup() }
        let service = SettingsLoginService()
        var creationCount = 0
        let controller = SettingsWindowController(
            model: setup.model,
            launchAtLoginFactory: {
                creationCount += 1
                let value = LaunchAtLoginController(service: service)
                return value
            }
        )

        XCTAssertFalse(controller.isSettingsViewLoaded)
        controller.showWindow(nil)
        XCTAssertTrue(controller.isSettingsViewLoaded)
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(controller.currentLaunchAtLoginEnabled, false)
        let window = try XCTUnwrap(controller.window)
        XCTAssertGreaterThanOrEqual(window.minSize.width, 940)
        XCTAssertFalse(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titlebarSeparatorStyle, .line)

        service.isEnabled = true
        controller.showWindow(nil)
        XCTAssertEqual(controller.currentLaunchAtLoginEnabled, true)

        controller.close()
        XCTAssertFalse(controller.isSettingsViewLoaded)
        XCTAssertNil(controller.currentLaunchAtLoginEnabled)

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
        pricing: PricingSnapshot = PricingSnapshot(catalogIDs: ["current"], rates: [], aliases: []),
        grantedProviders: Set<Provider> = [],
        approved: Bool = false,
        pickerURL: URL? = nil,
        coordinatorMutationGate: SettingsMutationGate? = nil,
        pricingCatalogStatus: PricingCatalogStatus? = nil,
        ledgerShutdownError: SettingsError? = nil,
        ledgerShutdownGate: SettingsMutationGate? = nil,
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
        let bundledCatalog = try bundledCatalogData()
        let ledger = SettingsLedger(
            pricing: pricing,
            rows: rows,
            recorder: recorder,
            appliedCatalog: bundledCatalog,
            shutdownError: ledgerShutdownError,
            shutdownGate: ledgerShutdownGate
        )
        let inbox = SettingsInbox(
            recorder: recorder,
            catalogStatus: pricingCatalogStatus
                ?? pricing.catalogIDs.last.map(PricingCatalogStatus.current)
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
            bundledCatalogData: bundledCatalog,
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

    private func bundledCatalogData() throws -> Data {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try Data(contentsOf: repository.appending(path: "Resources/tokenboard-pricing.json"))
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

    private func storedRate(
        usd: String,
        metric: UsageMetric = .inputUncached
    ) -> StoredPriceRate {
        StoredPriceRate(
            provider: .codex,
            canonicalModelID: "gpt-preview",
            metric: metric,
            usdPerMillion: Decimal(string: usd)!,
            effectiveFrom: "2026-01-01",
            effectiveTo: nil,
            provenanceURL: URL(string: "https://openai.com/api/pricing/")!,
            verifiedAt: "2026-08-05"
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

private enum SettingsError: Error {
    case injected
    case gateTimeout
}

private actor SettingsRecovery: AppDatabaseRecovering {
    private let backup: DatabaseBackup
    private var available: [DatabaseBackup]
    private let restoreError: DatabaseRecoveryError?
    private let availabilityError: DatabaseRecoveryError?
    private var restores = 0
    private var receivedBackups: [DatabaseBackup] = []
    private var shutdownAwaited = false
    private var mutations = 0
    private var preservationRetries = 0
    private let stageGate: SettingsMutationGate?
    private let preservationRetryGate: SettingsMutationGate?

    init(
        backup: DatabaseBackup,
        stageGate: SettingsMutationGate? = nil,
        restoreError: DatabaseRecoveryError? = nil,
        preservationRetryGate: SettingsMutationGate? = nil,
        availabilityError: DatabaseRecoveryError? = nil
    ) {
        self.backup = backup
        available = [backup]
        self.stageGate = stageGate
        self.restoreError = restoreError
        self.preservationRetryGate = preservationRetryGate
        self.availabilityError = availabilityError
    }

    func availableBackups() throws -> [DatabaseBackup] {
        if let availabilityError { throw availabilityError }
        return available
    }

    func restore(
        _ confirmedBackup: DatabaseBackup,
        afterShutdown: @Sendable () async throws -> Void
    ) async throws -> DatabaseBackup {
        receivedBackups.append(confirmedBackup)
        restores += 1
        try await afterShutdown()
        shutdownAwaited = true
        if let stageGate { await stageGate.suspend() }
        mutations += 1
        if let restoreError { throw restoreError }
        return backup
    }

    func restoreCount() -> Int { restores }
    func retryPreservation() async {
        preservationRetries += 1
        if let preservationRetryGate { await preservationRetryGate.suspend() }
    }
    func preservationRetryCount() -> Int { preservationRetries }
    func didAwaitShutdown() -> Bool { shutdownAwaited }
    func mutationCount() -> Int { mutations }
    func setAvailable(_ backups: [DatabaseBackup]) { available = backups }
    func received() -> [DatabaseBackup] { receivedBackups }
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
    private var appliedCatalog: Data
    private let rows: [DailyUsageRow]
    private let recorder: SettingsRecorder
    private var shutdownFailuresRemaining: Int
    private let shutdownGate: SettingsMutationGate?
    private var shutdowns = 0
    private var currentSkippedRecordCount = 3

    init(
        pricing: PricingSnapshot,
        rows: [DailyUsageRow],
        recorder: SettingsRecorder,
        appliedCatalog: Data,
        shutdownError: SettingsError?,
        shutdownGate: SettingsMutationGate? = nil
    ) {
        self.pricing = pricing
        self.appliedCatalog = appliedCatalog
        self.rows = rows
        self.recorder = recorder
        self.shutdownGate = shutdownGate
        shutdownFailuresRemaining = shutdownError == nil ? 0 : 1
    }

    func migrate() {}
    func integrityCheck() {}
    func latestAppliedPricingCatalogJSON() -> Data? { appliedCatalog }
    func applyPricingCatalog(
        _ catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        origin: String,
        validationSummary: String
    ) {
        appliedCatalog = canonicalJSON
    }
    func pricingSnapshot() -> PricingSnapshot { pricing }
    func usageRows(in interval: DateInterval?, calendar: Calendar) -> [DailyUsageRow] { rows }
    func skippedRecordCount() -> Int { currentSkippedRecordCount }
    func skippedRecordCountsByProvider() -> [Provider: Int] { [:] }
    func setSkippedRecordCount(_ count: Int) { currentSkippedRecordCount = count }
    func shutdown() async throws {
        shutdowns += 1
        recorder.append("ledger.shutdown")
        if let shutdownGate { await shutdownGate.suspend() }
        if shutdownFailuresRemaining > 0 {
            shutdownFailuresRemaining -= 1
            throw SettingsError.injected
        }
    }
    func shutdownCount() -> Int { shutdowns }
    func currentPricing() -> PricingSnapshot { pricing }
    func currentRows() -> [DailyUsageRow] { rows }

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

    func suspend() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func waitUntilEntered() async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !entered {
            guard clock.now < deadline else { throw SettingsError.gateTimeout }
            try await Task.sleep(for: .milliseconds(10))
        }
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
    private let recorder: SettingsRecorder
    private var starts = 0
    private let catalogStatus: PricingCatalogStatus?

    init(
        recorder: SettingsRecorder,
        catalogStatus: PricingCatalogStatus?
    ) {
        self.recorder = recorder
        self.catalogStatus = catalogStatus
    }

    func start() { starts += 1 }
    func quiesce() { recorder.append("inbox.quiesce") }
    func stop() { recorder.append("inbox.stop") }
    func status() -> PricingCatalogStatus? { catalogStatus }
    func updates() -> AsyncStream<PricingCatalogStatus> {
        AsyncStream { $0.finish() }
    }
    func exportCurrentSnapshot() { recorder.append("inbox.export") }
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
