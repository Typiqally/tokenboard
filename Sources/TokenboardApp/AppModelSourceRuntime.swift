import Foundation
import TokenboardCore

@MainActor
extension AppModel {
    func launchIngestion(refreshExisting: Bool) async {
        guard activity == nil, isReadyForSources else { return }
        let generation = lifecycleGeneration
        activityGeneration &+= 1
        let id = activityGeneration
        var next = state
        next.isImporting = true
        commitState(next)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runIngestion(refreshExisting: refreshExisting, generation: generation)
        }
        activity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if activity?.id == id {
            activity = nil
            if accepts(generation), state.lifecycle == .ready {
                next = state
                next.isImporting = false
                commitState(next)
            }
        }
    }

    func runIngestion(refreshExisting: Bool, generation: UInt64) async {
        guard readyGeneration == generation, accepts(generation), hasEveryGrant else { return }
        await coordinator.setEventBatchHandler { [weak self] result in
            Task { @MainActor [weak self] in
                await self?.consumeEventBatch(result, generation: generation)
            }
        }
        guard readyGeneration == generation, accepts(generation) else { return }

        do {
            let result: IngestionBatchResult
            switch coordinatorStatus {
            case .inactive:
                coordinatorStatus = .starting
                result = try await coordinator.start(roots: activeRoots())
                guard readyGeneration == generation, accepts(generation) else { return }
                coordinatorStatus = .active(runID: result.runID)
            case let .active(runID):
                guard refreshExisting else { return }
                result = await coordinator.refreshAll()
                guard readyGeneration == generation,
                      accepts(generation),
                      result.runID == runID else { return }
            case .starting:
                return
            }
            await applyBatchAndQuery(result, generation: generation)
        } catch {
            guard readyGeneration == generation, accepts(generation) else { return }
            coordinatorStatus = .inactive
            publishWarning("Historical import paused: \(Self.errorDescription(error))")
        }
    }

    func consumeEventBatch(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        guard readyGeneration == generation,
              accepts(generation),
              coordinatorStatus == .active(runID: result.runID) else { return }
        await applyBatchAndQuery(result, generation: generation)
    }

    func applyBatchAndQuery(
        _ result: IngestionBatchResult,
        generation: UInt64
    ) async {
        let period = state.selectedPeriod
        let (queryID, summaryResult) = await requestSummary(period: period)
        guard readyGeneration == generation, accepts(generation) else { return }

        var next = state
        let updated = now()
        for (provider, outcome) in result.providers {
            switch outcome {
            case let .success(discoveredFiles, _):
                next.sourceFileCounts[provider] = discoveredFiles
                next.sourceHealth[provider] = .healthy(
                    fileCount: discoveredFiles,
                    lastUpdated: updated
                )
            case let .attention(discoveredFiles, _):
                next.sourceFileCounts[provider] = discoveredFiles
                next.sourceHealth[provider] = .warning(
                    message: "Some logs need attention"
                )
            case let .failure(discoveredFiles, _):
                next.sourceFileCounts[provider] = discoveredFiles
                next.sourceHealth[provider] = .warning(message: "Import failed")
            }
        }
        next.lastUpdated = updated
        if queryID == queryGeneration,
           period == state.selectedPeriod,
           case let .success(summary) = summaryResult {
            lastSummary = summary
            next.presentation = makePresentation(summary: summary, state: next)
        } else if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        if case let .failure(error) = summaryResult, queryID == queryGeneration {
            for provider in Provider.allCases {
                next.sourceHealth[provider] = .warning(
                    message: "Summary unavailable: \(Self.errorDescription(error))"
                )
            }
            if let lastSummary {
                next.presentation = makePresentation(summary: lastSummary, state: next)
            }
        }
        commitState(next)
    }

    func launchReplacement(provider: Provider, url: URL) async {
        guard activity == nil, isReadyForSources else { return }
        let generation = lifecycleGeneration
        activityGeneration &+= 1
        let id = activityGeneration
        var next = state
        next.isImporting = true
        commitState(next)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReplacement(provider: provider, url: url, generation: generation)
        }
        activity = AppRuntimeActivity(id: id, task: task)
        await task.value
        if activity?.id == id {
            activity = nil
            if accepts(generation), state.lifecycle == .ready {
                next = state
                next.isImporting = false
                commitState(next)
            }
        }
    }

    func runReplacement(
        provider: Provider,
        url: URL,
        generation: UInt64
    ) async {
        guard readyGeneration == generation, accepts(generation) else { return }
        let prepared: PreparedSourceGrant
        do {
            prepared = try grantStore.prepareGrant(url: url, for: provider)
        } catch {
            return
        }

        let fileCount: Int
        do {
            fileCount = try await discoveredFileCount(under: prepared.root)
        } catch {
            prepared.close()
            return
        }
        guard readyGeneration == generation, accepts(generation) else {
            prepared.close()
            return
        }

        await coordinator.setEventBatchHandler(nil)
        await coordinator.stop()
        guard readyGeneration == generation, accepts(generation) else {
            prepared.close()
            return
        }
        coordinatorStatus = .inactive

        let oldGrant = activeGrants[provider]
        let newGrant = grantStore.commit(prepared, for: provider)
        activeGrants[provider] = newGrant
        oldGrant?.close()
        var next = state
        next.grantedProviders.insert(provider)
        next.sourceFileCounts[provider] = fileCount
        next.sourceHealth[provider] = .indexing(fileCount: fileCount)
        next.onboardingRequired = !preferences.historicalImportApproved || !hasEveryGrant
        commitState(next)

        if preferences.historicalImportApproved, hasEveryGrant {
            await runIngestion(refreshExisting: false, generation: generation)
        }
    }

    func requeryWithoutScanning() async {
        guard preferences.historicalImportApproved,
              isReadyForSources else { return }
        await querySelectedSummary()
    }

    func querySelectedSummary() async {
        let generation = lifecycleGeneration
        let period = state.selectedPeriod
        let (queryID, result) = await requestSummary(period: period)
        switch result {
        case let .success(summary):
            guard readyGeneration == generation,
                  accepts(generation),
                  queryGeneration == queryID,
                  state.selectedPeriod == period else { return }
            lastSummary = summary
            var next = state
            next.presentation = makePresentation(summary: summary, state: next)
            commitState(next)
        case let .failure(error):
            guard readyGeneration == generation,
                  accepts(generation),
                  queryGeneration == queryID else { return }
            publishWarning("Summary unavailable: \(Self.errorDescription(error))")
        }
    }

    func requestSummary(
        period: CalendarPeriod
    ) async -> (UInt64, Result<UsageSummary, Error>) {
        queryGeneration &+= 1
        let queryID = queryGeneration
        let queryService = self.queryService
        let requestedAt = now()
        let calendar = self.calendar
        let task = Task<Result<UsageSummary, Error>, Never> {
            do {
                return .success(try await queryService.summary(
                    period: period,
                    now: requestedAt,
                    calendar: calendar
                ))
            } catch {
                return .failure(error)
            }
        }
        inFlightQueries[queryID] = task
        let result = await task.value
        inFlightQueries[queryID] = nil
        return (queryID, result)
    }

    func makePresentation(
        summary: UsageSummary,
        state: AppPublishedState
    ) -> MenuPresentation {
        MenuPresentation(
            summary: summary,
            displayMetric: state.selectedDisplayMetric,
            hasHealthWarning: state.sourceHealth.values.contains(where: Self.isWarning)
        )
    }

    func discoveredFileCount(under root: URL) async throws -> Int {
        let discovery = self.discovery
        return try await Task.detached(priority: .utility) {
            try discovery.jsonlFiles(under: root).count
        }.value
    }

    func activeRoots() -> [Provider: URL] {
        Dictionary(uniqueKeysWithValues: activeGrants.map { ($0.key, $0.value.root) })
    }

    func closeActiveGrants() {
        for grant in activeGrants.values { grant.close() }
        activeGrants.removeAll()
    }

    func accepts(_ generation: UInt64) -> Bool {
        lifecycleGeneration == generation
            && state.lifecycle != .shuttingDown
            && state.lifecycle != .stopped
            && !Task.isCancelled
    }

    func publishWarning(_ message: String) {
        var next = state
        next.sourceHealth = warningHealth(message: message)
        if let lastSummary {
            next.presentation = makePresentation(summary: lastSummary, state: next)
        }
        commitState(next)
    }

    func warningHealth(message: String) -> [Provider: SourceHealth] {
        Dictionary(uniqueKeysWithValues: Provider.allCases.map {
            ($0, SourceHealth.warning(message: message))
        })
    }

    static func isWarning(_ health: SourceHealth) -> Bool {
        switch health {
        case .notGranted, .warning:
            true
        case .indexing, .healthy:
            false
        }
    }

    static func errorDescription(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}
