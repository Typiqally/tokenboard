import AppKit
import Combine
import SwiftUI
import TokenboardCore

enum HistorySection: String, CaseIterable, Equatable, Sendable {
    case usage
    case workPatterns = "work_patterns"
}

struct HistoryOpenRequest: Equatable, Sendable {
    let provider: Provider?
    let range: UsageHistoryRange
    let section: HistorySection

    init(
        provider: Provider?,
        range: UsageHistoryRange,
        section: HistorySection = .usage
    ) {
        self.provider = provider
        self.range = range
        self.section = section
    }
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var request: HistoryOpenRequest
    @Published private(set) var snapshot: UsageHistorySnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedPointID: String?

    private weak var model: AppModel?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0
    private var stateObservation: AnyCancellable?

    init(model: AppModel, request: HistoryOpenRequest) {
        self.model = model
        self.request = request
        stateObservation = model.$state.sink { [weak self] state in
            self?.receive(state)
        }
        load(request)
    }

    deinit {
        loadTask?.cancel()
    }

    var displayedBreakdown: UsageBreakdown? {
        guard let snapshot else { return nil }
        guard let selectedPointID else { return snapshot.breakdown }
        return snapshot.points.first { $0.selectionID == selectedPointID }?.breakdown
            ?? UsageBreakdown(
                tokenTotal: 0,
                knownAPIEquivalentUSD: 0,
                unpricedTokens: 0,
                exchangeRates: snapshot.breakdown.exchangeRates,
                providers: [],
                models: [],
                tokenTypes: UsageTokenCategory.allCases.map {
                    TokenTypeUsageBreakdown(category: $0, tokenTotal: 0)
                }
            )
    }

    var contextTitle: String {
        if let selectedPointID,
           let point = snapshot?.points.first(where: { $0.selectionID == selectedPointID }) {
            return UsageHistoryPresentation.axisLabel(point, range: request.range)
        }
        return UsageHistoryPresentation.rangeDescription(request.range)
    }

    func select(range: UsageHistoryRange) {
        guard range != request.range else { return }
        load(HistoryOpenRequest(
            provider: request.provider,
            range: range,
            section: request.section
        ))
    }

    func select(section: HistorySection) {
        guard section != request.section else { return }
        request = HistoryOpenRequest(
            provider: request.provider,
            range: request.range,
            section: section
        )
    }

    func retry() {
        load(request, ignoreCache: true)
    }

    func clearDaySelection() {
        selectedPointID = nil
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    private func receive(_ state: AppPublishedState) {
        guard request.provider == nil,
              let refreshed = state.historyState.snapshots?[request.range] else { return }
        snapshot = refreshed
        if let selectedPointID,
           !refreshed.points.contains(where: { $0.selectionID == selectedPointID }) {
            self.selectedPointID = nil
        }
        isLoading = false
        errorMessage = nil
    }

    func load(_ request: HistoryOpenRequest, ignoreCache: Bool = false) {
        self.request = request
        selectedPointID = nil
        errorMessage = nil
        loadTask?.cancel()
        loadGeneration &+= 1
        let generation = loadGeneration

        if !ignoreCache,
           request.provider == nil,
           let cached = model?.state.historyState.snapshots?[request.range] {
            snapshot = cached
            isLoading = false
            return
        }

        isLoading = true
        loadTask = Task { @MainActor [weak self, weak model] in
            guard let self, let model else { return }
            do {
                let result = try await model.historySnapshot(
                    range: request.range,
                    provider: request.provider,
                    ignoreCache: ignoreCache
                )
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.snapshot = result
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.loadGeneration == generation else { return }
                self.errorMessage = AppModel.errorDescription(error)
                self.isLoading = false
            }
        }
    }
}

struct HistoryDisclosureExpansion: Equatable {
    var providers: Bool
    var models: Bool
    var tokenTypes: Bool

    static let initial = HistoryDisclosureExpansion(
        providers: false,
        models: false,
        tokenTypes: false
    )
}

struct UsageHistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewModel: HistoryViewModel
    @State private var disclosureExpansion = HistoryDisclosureExpansion.initial

    var body: some View {
        Group {
            if viewModel.isLoading, viewModel.snapshot == nil {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading local history…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage, viewModel.snapshot == nil {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("History unavailable")
                        .font(.headline)
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                    Button("Retry") { viewModel.retry() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = viewModel.snapshot,
                      let breakdown = viewModel.displayedBreakdown {
                historyContent(snapshot: snapshot, breakdown: breakdown)
            }
        }
        .frame(
            minWidth: TokenboardSurfaceMetrics.historyMinimumSize.width,
            minHeight: TokenboardSurfaceMetrics.historyMinimumSize.height
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { viewModel.clearDaySelection() }
    }

    private func historyContent(
        snapshot: UsageHistorySnapshot,
        breakdown: UsageBreakdown
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: TokenboardVisualStyle.sectionSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        SurfaceEyebrow(title: viewModel.request.provider.map {
                            "History · \($0.displayName)"
                        } ?? "History")
                        Text(viewModel.request.section == .usage
                            ? viewModel.contextTitle
                            : "Work Patterns")
                            .font(.title2.weight(.semibold))
                    }
                    Spacer()
                    Picker("History view", selection: Binding(
                        get: { viewModel.request.section },
                        set: { viewModel.select(section: $0) }
                    )) {
                        Text("Usage").tag(HistorySection.usage)
                        Text("Work Patterns").tag(HistorySection.workPatterns)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 205)
                    UsageRangePicker(selection: Binding(
                        get: { viewModel.request.range },
                        set: { viewModel.select(range: $0) }
                    ))
                    .frame(width: 250)
                }

                if viewModel.request.section == .usage {
                    usageContent(snapshot: snapshot, breakdown: breakdown)
                } else if let workPatterns = snapshot.workPatterns {
                    WorkPatternView(
                        snapshot: workPatterns,
                        range: snapshot.range,
                        provider: snapshot.provider,
                        isBackfilling: model.isBackfillingWorkPatternHistory,
                        canBackfill: model.canBackfillWorkPatternHistory,
                        onBackfill: {
                            Task { @MainActor in
                                await model.backfillWorkPatternHistory()
                                if snapshot.provider != nil {
                                    viewModel.retry()
                                }
                            }
                        }
                    )
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.title2)
                        Text("Work patterns are not available yet")
                            .font(.headline)
                        Text("Tokenboard starts estimating focus time when five-minute local activity slices are available.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, minHeight: 320)
                }
            }
            .padding(TokenboardVisualStyle.pageInset)
        }
    }

    @ViewBuilder
    private func usageContent(
        snapshot: UsageHistorySnapshot,
        breakdown: UsageBreakdown
    ) -> some View {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ValueFormatter.exactTokens(breakdown.tokenTotal)) tokens")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(UsageHistoryPresentation.apiEquivalentTitle(
                        for: breakdown,
                        currency: model.selectedDisplayCurrency
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                UsageTrendChart(
                    snapshot: snapshot,
                    selectedPointID: $viewModel.selectedPointID
                )
                .frame(height: 155)

                HStack {
                    let comparison = UsageHistoryPresentation.comparison(
                        snapshot.comparison,
                        range: snapshot.range
                    )
                    Label(comparison.title, systemImage: comparison.systemImageName)
                        .foregroundStyle(snapshot.comparison.trendColor)
                        .accessibilityLabel(comparison.accessibilityTitle)
                    if viewModel.selectedPointID != nil {
                        Spacer()
                        Button("Show whole range") { viewModel.clearDaySelection() }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout)

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Why this number?")
                        .font(.headline)
                    Text("Additive local usage only. Reasoning output is never counted twice.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                disclosureRows(breakdown)
    }

    @ViewBuilder
    private func disclosureRows(_ breakdown: UsageBreakdown) -> some View {
        DisclosureGroup(isExpanded: $disclosureExpansion.providers) {
            VStack(spacing: 4) {
                ForEach(breakdown.providers, id: \.provider) { item in
                    BreakdownRow(title: item.provider.displayName, tokenTotal: item.tokenTotal)
                }
            }
            .padding(.top, 6)
        } label: {
            disclosureLabel(
                "Providers",
                summary: UsageHistoryPresentation.providerCountTitle(breakdown.providers.count)
            )
        }
        Divider()
        DisclosureGroup(isExpanded: $disclosureExpansion.models) {
            VStack(spacing: 4) {
                ForEach(
                    breakdown.models,
                    id: \.stableID
                ) { item in
                    BreakdownRow(
                        title: UsageHistoryPresentation.modelTitle(for: item.observedModelID),
                        tokenTotal: item.tokenTotal
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            disclosureLabel(
                "Models",
                summary: UsageHistoryPresentation.modelCountTitle(breakdown.models.count)
            )
        }
        Divider()
        DisclosureGroup(isExpanded: $disclosureExpansion.tokenTypes) {
            VStack(spacing: 4) {
                ForEach(breakdown.tokenTypes, id: \.category) { item in
                    BreakdownRow(
                        title: UsageHistoryPresentation.tokenCategoryTitle(item.category),
                        tokenTotal: item.tokenTotal
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            disclosureLabel(
                "Token types",
                summary: UsageHistoryPresentation.tokenTypeSummary
            )
        }
    }

    private func disclosureLabel(_ title: String, summary: String) -> some View {
        HStack {
            Text(title)
                .fontWeight(.medium)
            Spacer(minLength: 16)
            Text(summary)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel
    private var viewModel: HistoryViewModel?
    private var hostingController: NSHostingController<UsageHistoryView>?

    init(model: AppModel) {
        self.model = model
        super.init(window: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    func show(_ request: HistoryOpenRequest) {
        if let viewModel {
            viewModel.load(request)
        } else {
            loadWindow(request)
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        releaseHistoryWindow()
    }

    private func loadWindow(_ request: HistoryOpenRequest) {
        let viewModel = HistoryViewModel(model: model, request: request)
        let hostingController = NSHostingController(
            rootView: UsageHistoryView(model: model, viewModel: viewModel)
        )
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: TokenboardSurfaceMetrics.historySize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Tokenboard History"
        window.minSize = TokenboardSurfaceMetrics.historyMinimumSize
        window.titlebarSeparatorStyle = .line
        window.toolbarStyle = .unified
        window.contentViewController = hostingController
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.viewModel = viewModel
        self.hostingController = hostingController
        self.window = window
    }

    private func releaseHistoryWindow() {
        viewModel?.cancel()
        window?.delegate = nil
        window?.contentViewController = nil
        hostingController = nil
        viewModel = nil
        window = nil
    }
}

private extension ModelUsageBreakdown {
    var stableID: String { "\(provider.rawValue)/\(observedModelID)" }
}
