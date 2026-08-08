import Darwin
import Dispatch
import Foundation

public enum PricingCatalogInvalidReason: Equatable, Sendable {
    case invalidCatalog
    case unsafeFile
    case catalogTooLarge
    case unreadableCatalog
    case couldNotApply
}

public enum PricingCatalogStatus: Equatable, Sendable {
    case current(catalogID: String)
    case invalid(PricingCatalogInvalidReason)
}

public enum PricingCatalogError: Error, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case insecureManagedDirectory(String)
    case couldNotMonitor(Int32)
    case startInProgress
    case quiescing
    case noActiveCatalog
    case catalogUnavailable
    case catalogNotRegularFile
    case catalogHasMultipleLinks
    case catalogTooLarge
    case fileOperationFailed(String)
}

public actor PricingInbox {
    public static let currentCatalogFilename = "current-tokenboard-pricing.json"
    public static let temporaryCatalogFilename = "current-tokenboard-pricing.json.tmp"

    private let ledger: any LedgerStore
    private let applicationSupportDirectory: URL
    private let bundledCatalogData: Data
    private let fileSystem: any PricingCatalogFileSystem
    private var directorySource: DispatchSourceFileSystemObject?
    private var activeCatalog: ValidatedPricingCatalog?
    private var catalogStatus: PricingCatalogStatus?
    private var updateContinuations: [UUID: AsyncStream<PricingCatalogStatus>.Continuation] = [:]
    private var started = false
    private var isStarting = false
    private var isDetecting = false
    private var detectionRequested = false
    private var isQuiescing = false
    private var activeOperations = 0
    private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data
    ) {
        self.ledger = ledger
        self.applicationSupportDirectory = applicationSupportDirectory.standardizedFileURL
        self.bundledCatalogData = bundledCatalogData
        fileSystem = POSIXPricingCatalogFileSystem()
    }

    init(
        ledger: any LedgerStore,
        applicationSupportDirectory: URL,
        bundledCatalogData: Data,
        fileSystem: any PricingCatalogFileSystem
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
        guard !isStarting else { throw PricingCatalogError.startInProgress }
        guard !isQuiescing else { throw PricingCatalogError.quiescing }
        isStarting = true
        activeOperations += 1
        defer {
            isStarting = false
            finishOperation()
        }

        do {
            guard applicationSupportDirectory.isFileURL,
                  applicationSupportDirectory.path.hasPrefix("/") else {
                throw PricingCatalogError.invalidApplicationSupportDirectory
            }
            try fileSystem.open(rootPath: applicationSupportDirectory.path)
            let latestData = try await ledger.latestAppliedPricingCatalogJSON()
            let fallback = try validate(latestData ?? bundledCatalogData)
            let storedPricing = try await ledger.pricingSnapshot()
            let requiresAuthoritativeRewrite = storedPricing.catalogIDs != [fallback.catalogID]
            activeCatalog = fallback

            do {
                if let opened = try fileSystem.readIfPresent(name: Self.currentCatalogFilename) {
                    await applyCurrentFile(
                        opened.data,
                        force: requiresAuthoritativeRewrite
                    )
                } else {
                    if requiresAuthoritativeRewrite {
                        await applyCurrentFile(fallback.canonicalJSON, force: true)
                    }
                    try fileSystem.replaceCanonical(
                        fallback.canonicalJSON,
                        name: Self.currentCatalogFilename
                    )
                    if case .invalid = catalogStatus {} else {
                        publish(.current(catalogID: fallback.catalogID))
                    }
                }
            } catch {
                publish(.invalid(Self.invalidReason(for: error)))
            }

            let descriptor = try fileSystem.duplicatePricingDescriptor()
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .rename],
                queue: DispatchQueue(label: "com.tokenboard.pricing-catalog")
            )
            source.setCancelHandler { Darwin.close(descriptor) }
            source.setEventHandler { [weak self] in
                guard let inbox = self else { return }
                Task { await inbox.requestDetection() }
            }
            directorySource = source
            started = true
            source.resume()
        } catch {
            directorySource?.cancel()
            directorySource = nil
            fileSystem.close()
            activeCatalog = nil
            catalogStatus = nil
            throw error
        }
    }

    public func stop() throws {
        guard started || isStarting else { return }
        directorySource?.cancel()
        directorySource = nil
        fileSystem.close()
        started = false
        activeCatalog = nil
        catalogStatus = nil
        isDetecting = false
        detectionRequested = false
    }

    public func quiesce() async {
        isQuiescing = true
        guard activeOperations > 0 else { return }
        await withCheckedContinuation { continuation in
            quiescenceWaiters.append(continuation)
        }
    }

    public func status() -> PricingCatalogStatus? {
        catalogStatus
    }

    public func updates() -> AsyncStream<PricingCatalogStatus> {
        let id = UUID()
        return AsyncStream { continuation in
            updateContinuations[id] = continuation
            if let catalogStatus { continuation.yield(catalogStatus) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
        }
    }

    public func exportCurrentSnapshot() throws {
        guard started, let activeCatalog else {
            throw PricingCatalogError.noActiveCatalog
        }
        _ = try fileSystem.installCanonicalIfAbsent(
            activeCatalog.canonicalJSON,
            name: Self.currentCatalogFilename
        )
    }

    public var currentCatalogURL: URL {
        applicationSupportDirectory
            .appending(path: "Pricing", directoryHint: .isDirectory)
            .appending(path: Self.currentCatalogFilename)
    }

    private func requestDetection() async {
        guard started, !isQuiescing else { return }
        if isDetecting {
            detectionRequested = true
            return
        }
        isDetecting = true
        activeOperations += 1
        defer {
            isDetecting = false
            finishOperation()
        }
        repeat {
            detectionRequested = false
            do {
                if let opened = try fileSystem.readIfPresent(name: Self.currentCatalogFilename) {
                    await applyCurrentFile(opened.data)
                } else {
                    publish(.invalid(.unreadableCatalog))
                }
            } catch {
                publish(.invalid(Self.invalidReason(for: error)))
            }
        } while detectionRequested && !isQuiescing
    }

    private func applyCurrentFile(_ data: Data, force: Bool = false) async {
        let catalog: ValidatedPricingCatalog
        do {
            catalog = try validate(data)
        } catch {
            publish(.invalid(Self.invalidReason(for: error)))
            return
        }
        if !force, activeCatalog?.canonicalJSON == catalog.canonicalJSON {
            publish(.current(catalogID: catalog.catalogID))
            return
        }
        do {
            guard let validationSummary = PricingImportMetadata.validationSummary(
                for: catalog.schemaVersion
            ) else {
                throw PricingLedgerError.invalidImportMetadata
            }
            try await ledger.applyPricingCatalog(
                catalog,
                canonicalJSON: catalog.canonicalJSON,
                origin: PricingImportMetadata.agentCatalogOrigin,
                validationSummary: validationSummary
            )
            activeCatalog = catalog
            publish(.current(catalogID: catalog.catalogID))
        } catch {
            publish(.invalid(.couldNotApply))
        }
    }

    private func publish(_ status: PricingCatalogStatus) {
        guard catalogStatus != status else { return }
        catalogStatus = status
        updateContinuations.values.forEach { $0.yield(status) }
    }

    private func removeContinuation(_ id: UUID) {
        updateContinuations[id] = nil
    }

    private func validate(_ data: Data) throws -> ValidatedPricingCatalog {
        try PricingCatalogValidator().validate(PricingCatalogLoader().load(data))
    }

    private static func invalidReason(for error: Error) -> PricingCatalogInvalidReason {
        if let catalogError = error as? PricingCatalogError {
            switch catalogError {
            case .catalogNotRegularFile, .catalogHasMultipleLinks:
                return .unsafeFile
            case .catalogTooLarge:
                return .catalogTooLarge
            case .catalogUnavailable:
                return .unreadableCatalog
            default:
                return .unreadableCatalog
            }
        }
        if error is PricingCatalogValidationError || error is PricingCatalogLoadingError {
            return .invalidCatalog
        }
        return .unreadableCatalog
    }

    private func finishOperation() {
        precondition(activeOperations > 0)
        activeOperations -= 1
        guard activeOperations == 0 else { return }
        let waiters = quiescenceWaiters
        quiescenceWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
