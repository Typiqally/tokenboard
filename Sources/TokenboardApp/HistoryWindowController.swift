import AppKit
import SwiftUI
import TokenboardCore

struct HistoryOpenRequest: Equatable, Sendable {
    let provider: Provider?
    let range: UsageHistoryRange
}

@MainActor
final class HistoryViewModel: ObservableObject {
    @Published private(set) var request: HistoryOpenRequest
    @Published private(set) var snapshot: UsageHistorySnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    @Published var selectedDay: String?

    private weak var model: AppModel?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration: UInt64 = 0

    init(model: AppModel, request: HistoryOpenRequest) {
        self.model = model
        self.request = request
        load(request)
    }

    deinit {
        loadTask?.cancel()
    }

    var displayedBreakdown: UsageBreakdown? {
        guard let snapshot else { return nil }
        guard let selectedDay else { return snapshot.breakdown }
        return snapshot.points.first { $0.localDay.value == selectedDay }?.breakdown
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
        if let selectedDay,
           let point = snapshot?.points.first(where: { $0.localDay.value == selectedDay }) {
            return UsageHistoryPresentation.shortDate(point.localDay)
        }
        return UsageHistoryPresentation.rangeDescription(request.range)
    }

    func select(range: UsageHistoryRange) {
        guard range != request.range else { return }
        load(HistoryOpenRequest(provider: request.provider, range: range))
    }

    func retry() {
        load(request, ignoreCache: true)
    }

    func clearDaySelection() {
        selectedDay = nil
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
    }

    func load(_ request: HistoryOpenRequest, ignoreCache: Bool = false) {
        self.request = request
        selectedDay = nil
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

struct UsageHistoryView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var viewModel: HistoryViewModel
    @State private var providersExpanded = true
    @State private var modelsExpanded = true
    @State private var tokenTypesExpanded = true

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
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        SurfaceEyebrow(title: viewModel.request.provider.map {
                            "History · \($0.displayName)"
                        } ?? "History")
                        Text(viewModel.contextTitle)
                            .font(.title3.weight(.semibold))
                    }
                    Spacer()
                    UsageRangePicker(selection: Binding(
                        get: { viewModel.request.range },
                        set: { viewModel.select(range: $0) }
                    ))
                    .frame(width: 250)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("\(ValueFormatter.exactTokens(breakdown.tokenTotal)) tokens")
                        .font(.system(size: 36, weight: .semibold, design: .rounded))
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
                    selectedDay: $viewModel.selectedDay
                )
                .frame(height: 190)

                HStack {
                    Text(UsageHistoryPresentation.comparisonTitle(
                        snapshot.comparison,
                        range: snapshot.range
                    ))
                    .foregroundStyle(comparisonColor(snapshot.comparison))
                    if viewModel.selectedDay != nil {
                        Spacer()
                        Button("Show whole range") { viewModel.clearDaySelection() }
                            .buttonStyle(.link)
                    }
                }
                .font(.callout.weight(.medium))

                Divider()

                VStack(alignment: .leading, spacing: 6) {
                    SurfaceEyebrow(title: "Why this number?")
                    Text("Tokenboard totals additive usage from local logs. Reasoning output is already included in output tokens and is never counted twice.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                disclosureRows(breakdown)
            }
            .padding(TokenboardVisualStyle.pageInset)
        }
    }

    @ViewBuilder
    private func disclosureRows(_ breakdown: UsageBreakdown) -> some View {
        DisclosureGroup("Providers", isExpanded: $providersExpanded) {
            VStack(spacing: 4) {
                ForEach(breakdown.providers, id: \.provider) { item in
                    BreakdownRow(title: item.provider.displayName, tokenTotal: item.tokenTotal)
                }
            }
            .padding(.top, 6)
        }
        Divider()
        DisclosureGroup("Models", isExpanded: $modelsExpanded) {
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
        }
        Divider()
        DisclosureGroup("Token types", isExpanded: $tokenTypesExpanded) {
            VStack(spacing: 4) {
                ForEach(breakdown.tokenTypes, id: \.category) { item in
                    BreakdownRow(
                        title: UsageHistoryPresentation.tokenCategoryTitle(item.category),
                        tokenTotal: item.tokenTotal
                    )
                }
            }
            .padding(.top, 6)
        }
    }

    private func comparisonColor(_ comparison: UsageComparison) -> Color {
        if comparison.tokenDelta > 0 { return .green }
        if comparison.tokenDelta < 0 { return .orange }
        return .secondary
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
