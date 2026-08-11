import AppKit
import SwiftUI
import TokenboardCore

struct RichUsagePopoverView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let presentation = RichPopoverPresentation.make(
                state: model.state,
                startupError: nil,
                relativeTo: context.date
            )
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 13) {
                    header(presentation)
                    mainContent(presentation)
                }
                .padding(.horizontal, TokenboardVisualStyle.pageInset)
                .padding(.top, 17)
                .padding(.bottom, 12)

                Spacer(minLength: 0)
                Divider()
                footer
                    .padding(.horizontal, 12)
                    .frame(height: 48)
            }
            .frame(
                width: TokenboardSurfaceMetrics.popoverSize.width,
                height: TokenboardSurfaceMetrics.popoverSize.height
            )
            .background(.ultraThinMaterial)
        }
    }

    private func header(_ presentation: RichPopoverPresentation) -> some View {
        HStack {
            Menu {
                ForEach(UsageSelectionPresentation.periods, id: \.rawValue) { period in
                    Button {
                        Task { await model.select(period: period) }
                    } label: {
                        if period == model.selectedPeriod {
                            Label(
                                UsageSelectionPresentation.periodTitle(period),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(UsageSelectionPresentation.periodTitle(period))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    SurfaceEyebrow(title: presentation.periodTitle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Summary period, \(presentation.periodTitle)")

            Spacer()

            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: 5) {
                    Text(presentation.recencyTitle.uppercased())
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.35)
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Refresh local usage")
            .accessibilityLabel("\(presentation.recencyAccessibilityTitle). Refresh local usage.")
        }
    }

    @ViewBuilder
    private func mainContent(_ presentation: RichPopoverPresentation) -> some View {
        switch presentation.contentState {
        case .loading:
            loadingContent(presentation)
        case let .failed(message):
            failureContent(presentation, message: message)
        case .ready:
            readyContent(presentation)
        }
    }

    private func loadingContent(_ presentation: RichPopoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(presentation.headline)
                        .font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(presentation.apiValueTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            UsageRangePicker(selection: historyRangeBinding)
                .disabled(true)
            VStack(spacing: 10) {
                ForEach([0.72, 0.48, 0.85, 0.61], id: \.self) { width in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(nsColor: .quaternaryLabelColor))
                        .frame(maxWidth: 310 * width, minHeight: 8, maxHeight: 8)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
            Text("Totals appear as soon as local records are parsed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func failureContent(
        _ presentation: RichPopoverPresentation,
        message: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(presentation.headline)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Settings") {
                model.openSettings()
                dismiss()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 390, alignment: .topLeading)
    }

    private func readyContent(_ presentation: RichPopoverPresentation) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.headline)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(presentation.apiValueTitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }

            UsageRangePicker(selection: historyRangeBinding)

            trendContent(presentation)
                .frame(height: 152)

            if let comparison = presentation.comparison {
                Label(comparison.title, systemImage: comparison.systemImageName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(comparisonColor(presentation.snapshot?.comparison))
                    .accessibilityLabel(comparison.accessibilityTitle)
            }

            Divider()

            if presentation.providerRows.isEmpty {
                Text(presentation.emptyMessage ?? "Provider breakdown unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: 10) {
                    ForEach(presentation.providerRows) { row in
                        ProviderShareRow(row: row) {
                            model.openHistory(
                                provider: row.provider,
                                range: model.selectedHistoryRange
                            )
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func trendContent(_ presentation: RichPopoverPresentation) -> some View {
        if let snapshot = presentation.snapshot {
            if snapshot.breakdown.tokenTotal == 0 {
                VStack(spacing: 7) {
                    Image(systemName: "chart.bar")
                        .font(.title3)
                    Text(presentation.emptyMessage ?? "No usage recorded")
                        .font(.callout)
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                UsageTrendChart(
                    snapshot: snapshot,
                    selectedDay: .constant(nil),
                    compact: true
                )
            }
        } else {
            switch model.historyState {
            case .failed:
                VStack(spacing: 8) {
                    Text("Trend unavailable")
                        .foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.retryUsageHistory() } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .idle, .loading, .loaded:
                VStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading trend…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var historyRangeBinding: Binding<UsageHistoryRange> {
        Binding(
            get: { model.selectedHistoryRange },
            set: { model.select(historyRange: $0) }
        )
    }

    private var footer: some View {
        HStack(spacing: 4) {
            footerButton("History", systemImage: "clock.arrow.circlepath") {
                model.openHistory(range: model.selectedHistoryRange)
                dismiss()
            }
            Spacer()
            footerButton("Settings", systemImage: "gearshape") {
                model.openSettings()
                dismiss()
            }
            Menu {
                Button("Pricing…") {
                    model.openPricing()
                    dismiss()
                }
                Divider()
                Button("Quit Tokenboard") {
                    NSApplication.shared.terminate(nil)
                }
                .keyboardShortcut("q")
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.callout)
    }

    private func footerButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func comparisonColor(_ comparison: UsageComparison?) -> Color {
        guard let comparison else { return .secondary }
        if comparison.tokenDelta > 0 { return .green }
        if comparison.tokenDelta < 0 { return .orange }
        return .secondary
    }
}

struct StartupFailurePopoverView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Tokenboard unavailable")
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Divider()
            Button("Quit Tokenboard") { NSApplication.shared.terminate(nil) }
        }
        .padding(TokenboardVisualStyle.pageInset)
        .frame(
            width: TokenboardSurfaceMetrics.popoverSize.width,
            height: TokenboardSurfaceMetrics.popoverSize.height
        )
        .background(.ultraThinMaterial)
    }
}
