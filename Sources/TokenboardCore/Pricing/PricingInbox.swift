import Darwin
import Dispatch
import Foundation

public struct PendingPricingCandidate: Equatable, Sendable {
    public let catalog: ValidatedPricingCatalog
    public let canonicalJSON: Data
    public let diff: CatalogDiff
    public let sourceURL: URL

    public init(
        catalog: ValidatedPricingCatalog,
        canonicalJSON: Data,
        diff: CatalogDiff,
        sourceURL: URL
    ) {
        self.catalog = catalog
        self.canonicalJSON = canonicalJSON
        self.diff = diff
        self.sourceURL = sourceURL
    }
}

public enum PricingInboxError: Error, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case insecureManagedDirectory(String)
    case couldNotMonitorInbox(Int32)
    case startInProgress
    case resolutionInProgress
    case candidateAlreadyApplied
    case noPendingCandidate
    case candidateUnavailable
    case candidateNotRegularFile
    case candidateHasMultipleLinks
    case candidateTooLarge
    case candidateChanged
    case archiveConflict(String)
    case fileOperationFailed(String)
}

public actor PricingInbox {
    public static let candidateFilename = "tokenboard-pricing.candidate.json"
    public static let temporaryCandidateFilename = "tokenboard-pricing.candidate.json.tmp"
    static let processingFilenamePrefix = ".candidate-processing-"
    static let processingFilenameSuffix = ".json"

    private let ledger: any LedgerStore
    private let applicationSupportDirectory: URL
    private let bundledCatalogData: Data
    private let fileSystem: any PricingInboxFileSystem
    private var directorySource: DispatchSourceFileSystemObject?
    private var state: CandidateState = .idle
    private var activeCatalog: ValidatedPricingCatalog?
    private var activeSnapshot: PricingSnapshot?
    private var started = false
    private var isStarting = false
    private var isDetecting = false
    private var detectionRequested = false

    public init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
        fileSystem = POSIXPricingInboxFileSystem()
    }

    init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data,
        fileSystem: any PricingInboxFileSystem
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
        self.fileSystem = fileSystem
    }

    deinit {
        directorySource?.cancel()
        fileSystem.close()
    }

    public static func applicationSupport(
        ledger: any LedgerStore,
        bundledCatalogData: Data
    ) throws -> PricingInbox {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return PricingInbox(
            ledger: ledger,
            applicationSupportDirectory: support,
            bundledCatalogData: bundledCatalogData
        )
    }

    public func start() async throws {
        guard !started else { return }
        guard !isStarting else { throw PricingInboxError.startInProgress }
        isStarting = true
        defer { isStarting = false }

        do {
            guard applicationSupportDirectory.isFileURL,
                  applicationSupportDirectory.path.hasPrefix("/") else {
                throw PricingInboxError.invalidApplicationSupportDirectory
            }
            try fileSystem.open(rootPath: applicationSupportDirectory.path)
            let latestData = try await ledger.latestAppliedPricingCatalogJSON()
            let active = try validate(latestData ?? bundledCatalogData)
            activeCatalog = active
            activeSnapshot = snapshot(from: active)
            try fileSystem.replaceCanonical(
                active.canonicalJSON,
                in: .pricing,
                name: Self.currentCatalogFilename
            )
            try reconcileProcessingResidue(latestAppliedData: latestData)

            let descriptor = try fileSystem.duplicateInboxDescriptor()
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename],
                queue: DispatchQueue(label: "com.tokenboard.pricing-inbox")
            )
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                Task { await self?.requestCandidateDetection() }
            }
            directorySource = source
            started = true
            source.resume()
            await requestCandidateDetection()
        } catch {
            directorySource?.cancel()
            directorySource = nil
            fileSystem.close()
            activeCatalog = nil
            activeSnapshot = nil
            state = .idle
            throw error
        }
    }

    public func stop() throws {
        switch state {
        case .resolving, .rejectedFinalizing:
            throw PricingInboxError.resolutionInProgress
        case .committed:
            throw PricingInboxError.candidateAlreadyApplied
        case .idle, .pending:
            break
        }
        guard started || isStarting else { return }
        directorySource?.cancel()
        directorySource = nil
        fileSystem.close()
        started = false
        activeCatalog = nil
        activeSnapshot = nil
        state = .idle
    }

    public func pendingCandidate() -> PendingPricingCandidate? {
        guard case let .pending(record) = state else { return nil }
        return record.preview
    }

    public func applyPending() async throws {
        switch state {
        case .resolving, .rejectedFinalizing:
            throw PricingInboxError.resolutionInProgress
        case let .committed(committed):
            try finalizeCommitted(committed)
            return
        case .idle:
            throw PricingInboxError.noPendingCandidate
        case let .pending(pending):
            try await apply(pending)
        }
    }

    public func rejectPending() async throws {
        let pending: PendingRecord
        switch state {
        case .resolving:
            throw PricingInboxError.resolutionInProgress
        case let .rejectedFinalizing(rejected):
            try finalizeRejected(rejected)
            return
        case .committed:
            throw PricingInboxError.candidateAlreadyApplied
        case .idle:
            throw PricingInboxError.noPendingCandidate
        case let .pending(record):
            pending = record
        }

        state = .resolving(pending)
        do {
            let isolated = try isolateAndVerify(pending)
            state = .resolving(isolated)
            try installArchive(
                isolated.preview.canonicalJSON,
                catalogID: isolated.preview.catalog.catalogID,
                directory: .rejected
            )
            let rejected = RejectedRecord(processingName: isolated.location.processingName)
            do {
                try fileSystem.removeInbox(name: rejected.processingName)
            } catch {
                if Self.completedRemoval(error, name: rejected.processingName) {
                    state = .rejectedFinalizing(rejected)
                }
                throw error
            }
            state = .idle
            requestDetectionAfterResolution()
        } catch {
            if case .rejectedFinalizing = state { throw error }
            restorePreCommitCandidate(pendingRecordFromState(fallback: pending))
            throw error
        }
    }

    private func finalizeRejected(_ rejected: RejectedRecord) throws {
        guard case .rejectedFinalizing = state else {
            throw PricingInboxError.noPendingCandidate
        }
        try fileSystem.removeInbox(name: rejected.processingName)
        state = .idle
        requestDetectionAfterResolution()
    }

    private func apply(_ pending: PendingRecord) async throws {
        state = .resolving(pending)
        let isolated: PendingRecord
        do {
            isolated = try isolateAndVerify(pending)
            state = .resolving(isolated)
        } catch {
            restorePreCommitCandidate(pendingRecordFromState(fallback: pending))
            throw error
        }

        do {
            try await ledger.applyPricingCatalog(
                isolated.preview.catalog,
                canonicalJSON: isolated.preview.canonicalJSON,
                origin: PricingImportMetadata.agentCandidateOrigin,
                validationSummary: PricingImportMetadata.schemaV1ValidSummary
            )
        } catch {
            restorePreCommitCandidate(isolated)
            throw error
        }

        let committed = CommittedRecord(
            preview: isolated.preview,
            processingName: isolated.location.processingName
        )
        activeCatalog = isolated.preview.catalog
        activeSnapshot = snapshot(from: isolated.preview.catalog)
        state = .committed(committed)
        try finalizeCommitted(committed)
    }

    private func finalizeCommitted(_ committed: CommittedRecord) throws {
        guard case .committed = state else {
            throw PricingInboxError.noPendingCandidate
        }
        try fileSystem.replaceCanonical(
            committed.preview.canonicalJSON,
            in: .pricing,
            name: Self.currentCatalogFilename
        )
        try installArchive(
            committed.preview.canonicalJSON,
            catalogID: committed.preview.catalog.catalogID,
            directory: .applied
        )
        try fileSystem.removeInbox(name: committed.processingName)
        state = .idle
        requestDetectionAfterResolution()
    }

    private func isolateAndVerify(_ record: PendingRecord) throws -> PendingRecord {
        var isolated = record
        switch record.location {
        case .candidate:
            let processing = Self.processingFilename()
            do {
                try fileSystem.moveInbox(from: Self.candidateFilename, to: processing, exclusive: true)
            } catch {
                if Self.completedMove(
                    error,
                    from: Self.candidateFilename,
                    to: processing
                ) {
                    isolated.location = .processing(processing)
                    state = .resolving(isolated)
                }
                throw error
            }
            isolated.location = .processing(processing)
            state = .resolving(isolated)
        case .processing:
            break
        }
        guard let opened = try fileSystem.readIfPresent(
            in: .inbox,
            name: isolated.location.processingName
        ) else {
            throw PricingInboxError.candidateUnavailable
        }
        guard opened.identity == isolated.identity else {
            throw PricingInboxError.candidateChanged
        }
        let catalog = try validate(opened.data)
        guard catalog.canonicalJSON == isolated.preview.canonicalJSON else {
            throw PricingInboxError.candidateChanged
        }
        return isolated
    }

    private func restorePreCommitCandidate(_ record: PendingRecord) {
        var restored = record
        if case let .processing(name) = record.location {
            do {
                try fileSystem.moveInbox(from: name, to: Self.candidateFilename, exclusive: true)
                restored.location = .candidate
            } catch {
                restored.location = Self.completedMove(
                    error,
                    from: name,
                    to: Self.candidateFilename
                ) ? .candidate : .processing(name)
            }
        }
        do {
            let name = restored.location.filename
            guard let opened = try fileSystem.readIfPresent(in: .inbox, name: name),
                  opened.identity == restored.identity,
                  try validate(opened.data).canonicalJSON == restored.preview.canonicalJSON else {
                state = .idle
                requestDetectionAfterResolution()
                return
            }
            state = .pending(restored)
            requestDetectionAfterResolution()
        } catch {
            state = .idle
            requestDetectionAfterResolution()
        }
    }

    private func pendingRecordFromState(fallback: PendingRecord) -> PendingRecord {
        guard case let .resolving(record) = state else { return fallback }
        return record
    }

    private func requestDetectionAfterResolution() {
        guard detectionRequested else { return }
        Task { await self.requestCandidateDetection() }
    }

    private func requestCandidateDetection() async {
        detectionRequested = true
        guard !isDetecting, state.allowsDetection else { return }
        isDetecting = true
        repeat {
            detectionRequested = false
            detectCandidate()
        } while detectionRequested && state.allowsDetection
        isDetecting = false
    }

    private func detectCandidate() {
        guard let activeSnapshot else {
            state = .idle
            return
        }
        do {
            guard let opened = try fileSystem.readIfPresent(in: .inbox, name: Self.candidateFilename) else {
                state = .idle
                return
            }
            let catalog = try validate(opened.data)
            let preview = PendingPricingCandidate(
                catalog: catalog,
                canonicalJSON: catalog.canonicalJSON,
                diff: CatalogDiff.compare(candidate: catalog, against: activeSnapshot),
                sourceURL: candidateURL
            )
            state = .pending(PendingRecord(
                preview: preview,
                identity: opened.identity,
                location: .candidate
            ))
        } catch {
            state = .idle
        }
    }

    private func reconcileProcessingResidue(latestAppliedData: Data?) throws {
        let latestApplied = try latestAppliedData.map(validate)
        var restoredUncommitted = false
        for name in try fileSystem.listInbox() where Self.isProcessingFilename(name) {
            guard let opened = try? fileSystem.readIfPresent(in: .inbox, name: name),
                  let catalog = try? validate(opened.data) else {
                continue
            }
            if let latestApplied,
               catalog.canonicalJSON == latestApplied.canonicalJSON {
                try installArchive(
                    latestApplied.canonicalJSON,
                    catalogID: latestApplied.catalogID,
                    directory: .applied
                )
                try fileSystem.removeInbox(name: name)
            } else if !restoredUncommitted {
                do {
                    try fileSystem.moveInbox(from: name, to: Self.candidateFilename, exclusive: true)
                    restoredUncommitted = true
                } catch {
                    if Self.completedMove(error, from: name, to: Self.candidateFilename) {
                        restoredUncommitted = true
                    } else {
                        continue
                    }
                }
            }
        }
    }

    private func installArchive(
        _ canonicalJSON: Data,
        catalogID: String,
        directory: PricingInboxDirectory
    ) throws {
        let name = "\(catalogID).json"
        if try fileSystem.installCanonicalIfAbsent(canonicalJSON, in: directory, name: name) {
            return
        }
        guard let existing = try fileSystem.readIfPresent(in: directory, name: name) else {
            throw PricingInboxError.archiveConflict(name)
        }
        let existingCatalog = try validate(existing.data)
        guard existingCatalog.canonicalJSON == canonicalJSON else {
            throw PricingInboxError.archiveConflict(name)
        }
    }

    private func snapshot(from catalog: ValidatedPricingCatalog) -> PricingSnapshot {
        var rates: [StoredPriceRate] = []
        var aliases: [StoredModelAlias] = []
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
        return PricingSnapshot(catalogIDs: [catalog.catalogID], rates: rates, aliases: aliases)
    }

    private func validate(_ data: Data) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))
    }

    private static func processingFilename() -> String {
        "\(processingFilenamePrefix)\(UUID().uuidString)\(processingFilenameSuffix)"
    }

    private static func completedMove(_ error: Error, from: String, to: String) -> Bool {
        guard let mutationError = error as? PricingInboxMutationError else { return false }
        return mutationError.mutationCompleted
            && mutationError.mutation == .moveInbox(from: from, to: to)
    }

    private static func completedRemoval(_ error: Error, name: String) -> Bool {
        guard let mutationError = error as? PricingInboxMutationError else { return false }
        return mutationError.mutationCompleted
            && mutationError.mutation == .removeInbox(name: name)
    }

    private static func isProcessingFilename(_ name: String) -> Bool {
        name.hasPrefix(processingFilenamePrefix)
            && name.hasSuffix(processingFilenameSuffix)
            && name.count > processingFilenamePrefix.count + processingFilenameSuffix.count
    }

    private static let currentCatalogFilename = "current-tokenboard-pricing.json"

    private var candidateURL: URL {
        applicationSupportDirectory
            .appending(path: "Pricing/Inbox", directoryHint: .isDirectory)
            .appending(path: Self.candidateFilename)
    }
}

private enum CandidateState: Sendable {
    case idle
    case pending(PendingRecord)
    case resolving(PendingRecord)
    case rejectedFinalizing(RejectedRecord)
    case committed(CommittedRecord)

    var allowsDetection: Bool {
        switch self {
        case .idle:
            true
        case let .pending(record):
            record.location.isCandidate
        case .resolving, .rejectedFinalizing, .committed:
            false
        }
    }
}

private struct PendingRecord: Sendable {
    let preview: PendingPricingCandidate
    let identity: PricingInboxFileIdentity
    var location: CandidateLocation
}

private struct CommittedRecord: Sendable {
    let preview: PendingPricingCandidate
    let processingName: String
}

private struct RejectedRecord: Sendable {
    let processingName: String
}

private enum CandidateLocation: Sendable {
    case candidate
    case processing(String)

    var filename: String {
        switch self {
        case .candidate: PricingInbox.candidateFilename
        case let .processing(name): name
        }
    }

    var processingName: String {
        switch self {
        case .candidate: PricingInbox.candidateFilename
        case let .processing(name): name
        }
    }

    var isCandidate: Bool {
        if case .candidate = self { return true }
        return false
    }

}
