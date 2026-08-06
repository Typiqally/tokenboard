import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func refreshSettings() async {
        await refreshSettings(statusMessage: nil)
    }

    func copyAgentPrompt(source: AgentPricingSource) async {
        do {
            try await pricingInbox.exportCurrentSnapshot()
            let inbox = applicationPaths.pricing.appending(
                path: "Inbox",
                directoryHint: .isDirectory
            )
            let prompt = AgentPromptBuilder().build(
                source: source,
                paths: AgentPricingPaths(
                    currentCatalog: applicationPaths.pricing.appending(
                        path: PricingInbox.currentCatalogFilename
                    ),
                    temporaryCandidate: inbox.appending(
                        path: PricingInbox.temporaryCandidateFilename
                    ),
                    finalCandidate: inbox.appending(path: PricingInbox.candidateFilename)
                )
            )
            guard pasteboard.replace(with: prompt) else {
                throw AppSettingsError.pasteboardWriteFailed
            }
            setSettingsStatus("Prompt copied · Tokenboard made no network request")
        } catch {
            setSettingsStatus("Prompt copy failed: \(Self.errorDescription(error))")
        }
    }

    func applyPendingPricing() async {
        if settingsState.pricing.pendingCandidate == nil {
            await refreshSettings()
        }
        guard settingsState.pricing.canApply else {
            setSettingsStatus("Pricing candidate has conflicts that block Apply")
            return
        }
        setSettingsLoading(true)
        do {
            try await pricingInbox.applyPending()
            await querySelectedSummary()
            await refreshSettings(
                statusMessage: "Pricing applied · API-equivalent value refreshed"
            )
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Pricing apply failed: \(Self.errorDescription(error))")
        }
    }

    func rejectPendingPricing() async {
        guard settingsState.pricing.pendingCandidate != nil else {
            setSettingsStatus("No pending pricing candidate")
            return
        }
        setSettingsLoading(true)
        do {
            try await pricingInbox.rejectPending()
            await refreshSettings(
                statusMessage: "Pricing candidate rejected · Active pricing unchanged"
            )
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Pricing rejection failed: \(Self.errorDescription(error))")
        }
    }

    func changeSource(_ provider: Provider) async {
        await chooseSource(provider)
        await refreshSettings()
    }

    func revokeSource(_ provider: Provider) async {
        guard isReadyForSources else { return }
        if let activity { await activity.task.value }
        guard isReadyForSources else { return }

        let generation = lifecycleGeneration
        let oldRoots = activeRoots()
        let oldCoordinatorWasActive = coordinatorStatus.isActive
        var remainingRoots = oldRoots
        remainingRoots[provider] = nil
        prepareForCoordinatorStart()

        do {
            let runID = try await coordinator.revokeSource(
                provider,
                remainingRoots: remainingRoots
            )
            guard readyGeneration == generation, accepts(generation) else { return }
            if let runID {
                coordinatorStatus = .active(runID: runID)
                discardPendingResults(exceptRunID: runID)
                await processPendingIngestionResults(generation: generation)
            } else {
                coordinatorStatus = .inactive
                discardPendingResults(exceptRunID: UInt64.max)
            }

            grantStore.revoke(provider)
            let revokedGrant = activeGrants.removeValue(forKey: provider)
            revokedGrant?.close()
            var next = state
            next.grantedProviders.remove(provider)
            next.sourceFileCounts[provider] = nil
            next.sourceHealth[provider] = .notGranted
            next.onboardingRequired = true
            commitState(next)
            await querySelectedSummary()
            await refreshSettings(statusMessage: "Source access revoked · Committed totals retained")
        } catch {
            coordinatorStatus = .inactive
            if oldCoordinatorWasActive, oldRoots.count == Provider.allCases.count {
                do {
                    prepareForCoordinatorStart()
                    beginCoordinatorInventoryRequest()
                    let restored: IngestionBatchResult
                    do {
                        restored = try await coordinator.start(roots: oldRoots)
                    } catch {
                        completeCoordinatorInventoryRequest()
                        throw error
                    }
                    guard readyGeneration == generation, accepts(generation) else {
                        completeCoordinatorInventoryRequest()
                        return
                    }
                    await activateRestoredCoordinator(restored, generation: generation)
                } catch {
                    coordinatorStatus = .inactive
                    publishWarning(
                        "Historical import paused: \(Self.errorDescription(error))"
                    )
                }
            }
            setSettingsStatus("Source revoke failed: \(Self.errorDescription(error))")
        }
    }

    func revealLocalData() {
        localDataRevealer.reveal([applicationPaths.root])
    }

    private func refreshSettings(statusMessage: String?) async {
        guard await ensureReady(retryFailed: false) else {
            setSettingsStatus("Settings unavailable until startup completes")
            return
        }
        setSettingsLoading(true)
        do {
            let interval = state.selectedPeriod.interval(
                containing: now(),
                calendar: calendar
            )
            let pricing = try await ledger.pricingSnapshot()
            let rows = try await ledger.usageRows(in: interval, calendar: calendar)
            let skippedCount = try await ledger.skippedRecordCount()
            let pending = await pricingInbox.pendingCandidate()
            let preview = try pending.map {
                try PricingPreview.make(
                    rows: rows,
                    currentPricing: pricing,
                    candidate: $0.catalog
                )
            }

            commitSettingsState(AppSettingsState(
                sources: sourceSettings(),
                pricing: PricingSettingsState(
                    activeCatalogIDs: pricing.catalogIDs.sorted(),
                    verificationDates: Array(Set(pricing.rates.map(\.verifiedAt))).sorted(),
                    provenanceURLs: Array(Set(pricing.rates.map(\.provenanceURL))).sorted {
                        $0.absoluteString < $1.absoluteString
                    },
                    unpricedModels: try unpricedModels(rows: rows, pricing: pricing),
                    pendingCandidate: pending,
                    preview: preview,
                    validationConflicts: []
                ),
                diagnostics: SettingsDiagnosticsState(
                    skippedRecordCount: skippedCount,
                    parserVersions: [
                        .claudeCode: ClaudeCodeAdapter.parserVersion,
                        .codex: CodexAdapter.parserVersion
                    ]
                ),
                statusMessage: statusMessage,
                isLoading: false
            ))
        } catch {
            setSettingsLoading(false)
            setSettingsStatus("Settings unavailable: \(Self.errorDescription(error))")
        }
    }

    private func sourceSettings() -> [Provider: SourceSettingsState] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map { provider in
            let health = state.sourceHealth[provider] ?? .notGranted
            let lastScan: Date?
            if case let .healthy(_, updated) = health {
                lastScan = updated
            } else {
                lastScan = nil
            }
            return (
                provider,
                SourceSettingsState(
                    provider: provider,
                    resolvedPath: activeGrants[provider]?.root.path,
                    accessStatus: activeGrants[provider] == nil
                        ? "Not granted"
                        : "Read-only access",
                    fileCount: state.sourceFileCounts[provider, default: 0],
                    lastScan: lastScan,
                    health: health
                )
            )
        })
    }

    private func unpricedModels(
        rows: [DailyUsageRow],
        pricing: PricingSnapshot
    ) throws -> [String] {
        var values = Set<String>()
        let resolver = PriceResolver()
        for row in rows where row.aggregation == .additive {
            let result = try resolver.resolve(rows: [row], pricing: pricing)
            if result.unpricedTokens > 0 {
                values.insert("\(row.provider.rawValue)/\(row.observedModelID)")
            }
        }
        return values.sorted()
    }

    private func setSettingsLoading(_ isLoading: Bool) {
        var next = settingsState
        next.isLoading = isLoading
        commitSettingsState(next)
    }

    private func setSettingsStatus(_ status: String) {
        var next = settingsState
        next.statusMessage = status
        commitSettingsState(next)
    }
}

private enum AppSettingsError: LocalizedError {
    case pasteboardWriteFailed

    var errorDescription: String? {
        "The pasteboard did not accept plain text"
    }
}
