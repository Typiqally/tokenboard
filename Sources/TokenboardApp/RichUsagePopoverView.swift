import AppKit
import SwiftUI
import TokenboardCore

struct RichUsagePopoverView: View {
    @ObservedObject var model: AppModel
    let dismiss: () -> Void
    @State private var isRefreshPending = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let presentation = RichPopoverPresentation.make(
                state: model.state,
                startupError: nil,
                relativeTo: context.date
            )
            let refreshPresentation = RichPopoverRefreshPresentation.make(
                recencyTitle: presentation.recencyTitle,
                recencyAccessibilityTitle: presentation.recencyAccessibilityTitle,
                isRefreshPending: isRefreshPending,
                isImporting: model.state.isImporting
            )
            VStack(spacing: 0) {
                VStack(
                    alignment: .leading,
                    spacing: TokenboardSurfaceMetrics.popoverHeaderSpacing
                ) {
                    header(presentation, refreshPresentation: refreshPresentation)
                    mainContent(presentation)
                }
                .padding(.horizontal, TokenboardVisualStyle.pageInset)
                .padding(.top, TokenboardSurfaceMetrics.popoverTopPadding)
                .padding(.bottom, 12)

                Spacer(minLength: 0)
                Divider()
                footer
                    .padding(.horizontal, 12)
                    .frame(height: TokenboardSurfaceMetrics.popoverFooterHeight)
            }
            .frame(
                width: TokenboardSurfaceMetrics.popoverSize.width,
                height: TokenboardSurfaceMetrics.popoverSize.height
            )
            .background(.ultraThinMaterial)
        }
    }

    private func header(
        _ presentation: RichPopoverPresentation,
        refreshPresentation: RichPopoverRefreshPresentation
    ) -> some View {
        HStack {
            Menu {
                ForEach(RichPopoverPeriodOption.all) { option in
                    Button {
                        Task { await model.select(period: option.period) }
                    } label: {
                        Text(option.title)
                    }
                }
            } label: {
                SurfaceEyebrow(title: presentation.periodTitle)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .accessibilityLabel("Summary period, \(presentation.periodTitle)")

            Spacer()

            Button {
                guard !refreshPresentation.isInProgress else { return }
                isRefreshPending = true
                Task { @MainActor in
                    await model.refresh()
                    isRefreshPending = false
                }
            } label: {
                HStack(spacing: 5) {
                    Text(refreshPresentation.title)
                        .font(.system(size: 10, weight: .medium))
                        .tracking(0.35)
                    if refreshPresentation.isInProgress {
                        ProgressView()
                            .controlSize(.mini)
                            .frame(width: 12, height: 12)
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(refreshPresentation.isInProgress)
            .help(refreshPresentation.helpTitle)
            .accessibilityLabel(refreshPresentation.accessibilityTitle)

            let quitAction = RichPopoverHeaderAction.quit
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: quitAction.systemImageName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help(quitAction.title)
            .accessibilityLabel(quitAction.title)
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
        VStack(
            alignment: .leading,
            spacing: TokenboardSurfaceMetrics.popoverContentSpacing
        ) {
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
                .frame(width: TokenboardSurfaceMetrics.popoverContentWidth)
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
        VStack(
            alignment: .leading,
            spacing: TokenboardSurfaceMetrics.popoverContentSpacing
        ) {
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
        VStack(
            alignment: .leading,
            spacing: TokenboardSurfaceMetrics.popoverContentSpacing
        ) {
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
                .frame(width: TokenboardSurfaceMetrics.popoverContentWidth)

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
                    selectedPointID: .constant(nil),
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
            ForEach(RichPopoverFooterAction.allCases, id: \.self) { action in
                footerButton(action)
                if action != RichPopoverFooterAction.allCases.last {
                    Spacer()
                }
            }
        }
        .font(.callout)
    }

    private func footerButton(_ action: RichPopoverFooterAction) -> some View {
        Button {
            perform(action)
        } label: {
            Label(action.title, systemImage: action.systemImageName)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func perform(_ action: RichPopoverFooterAction) {
        switch action {
        case .history:
            model.openHistory(range: model.selectedHistoryRange)
            dismiss()
        case .settings:
            model.openSettings()
            dismiss()
        }
    }

    private func comparisonColor(_ comparison: UsageComparison?) -> Color {
        comparison?.trendColor ?? .secondary
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
