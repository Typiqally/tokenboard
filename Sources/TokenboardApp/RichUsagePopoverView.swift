import AppKit
import SwiftUI
import TokenboardCore

@MainActor
final class RichPopoverVisibility: ObservableObject {
    @Published var isPresented = false
}

struct RichUsagePopoverView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var visibility: RichPopoverVisibility
    let dismiss: () -> Void
    @State private var isRefreshPending = false
    @State private var chartSelection = PopoverChartSelection()

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
            let companion = model.companionPresentation(at: context.date)
            VStack(spacing: 0) {
                if let companion {
                    companionContent(
                        presentation,
                        refreshPresentation: refreshPresentation,
                        companion: companion
                    )
                } else {
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
                }

                Spacer(minLength: 0)
                if companion != nil {
                    companionFooter
                } else {
                    Divider()
                    footer
                        .padding(.horizontal, 12)
                        .frame(height: TokenboardSurfaceMetrics.popoverFooterHeight)
                }
            }
            .frame(
                width: TokenboardSurfaceMetrics.popoverSize.width,
                height: TokenboardSurfaceMetrics.popoverSize(
                    companionEnabled: companion != nil
                ).height
            )
            .background(.ultraThinMaterial)
        }
        // Companion scenes inside the popover animate only while this
        // window is genuinely on screen.
        .tracksCompanionSceneVisibility()
        .onChange(of: model.selectedHistoryRange) { _, _ in
            chartSelection.clearAll()
        }
        .onChange(of: model.state.lastUpdated) { _, _ in
            chartSelection.clearAll()
        }
        .onChange(of: visibility.isPresented) { _, isPresented in
            if !isPresented { chartSelection.clearAll() }
        }
    }

    private func companionContent(
        _ presentation: RichPopoverPresentation,
        refreshPresentation: RichPopoverRefreshPresentation,
        companion: CompanionPresentation
    ) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CompanionPanorama(
                    presentation: companion,
                    isAmbientMotionActive: visibility.isPresented
                )

                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(
                            color: .black.opacity(
                                TokenboardSurfaceMetrics.companionTopScrimOpacity
                            ),
                            location: 0
                        ),
                        .init(
                            color: .black.opacity(0.50),
                            location: 64 / TokenboardSurfaceMetrics.companionPanoramaHeight
                        ),
                        .init(
                            color: .black.opacity(0.18),
                            location: 112 / TokenboardSurfaceMetrics.companionPanoramaHeight
                        ),
                        .init(
                            color: .clear,
                            location: 160 / TokenboardSurfaceMetrics.companionPanoramaHeight
                        ),
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
                .allowsHitTesting(false)

                VStack(
                    alignment: .leading,
                    spacing: TokenboardSurfaceMetrics.companionHUDSpacing
                ) {
                    header(
                        presentation,
                        refreshPresentation: refreshPresentation,
                        overArtwork: true
                    )
                    panoramaHeadline(presentation)
                }
                .padding(.horizontal, TokenboardVisualStyle.pageInset)
                .padding(.top, TokenboardSurfaceMetrics.companionHUDTopPadding)
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
                .shadow(color: .black.opacity(0.58), radius: 3, y: 1)
            }
            .frame(
                width: TokenboardSurfaceMetrics.popoverSize.width,
                height: TokenboardSurfaceMetrics.companionPanoramaHeight
            )

            companionMainContent(presentation)
                .padding(.horizontal, TokenboardVisualStyle.pageInset)
                .padding(.top, TokenboardSurfaceMetrics.popoverContentSpacing)
                .padding(.bottom, TokenboardSurfaceMetrics.companionContentBottomPadding)
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private func panoramaHeadline(_ presentation: RichPopoverPresentation) -> some View {
        switch presentation.contentState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                panoramaHeadlineText(presentation)
            }
        case .failed, .ready:
            panoramaHeadlineText(presentation)
        }
    }

    private func panoramaHeadlineText(
        _ presentation: RichPopoverPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(presentation.headline)
                .font(.system(
                    size: TokenboardSurfaceMetrics.companionHeadlineFontSize,
                    weight: .semibold,
                    design: .rounded
                ))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(presentation.apiValueTitle)
                .font(.system(size: TokenboardSurfaceMetrics.companionSubtitleFontSize))
                .foregroundStyle(.white.opacity(0.82))
        }
    }

    @ViewBuilder
    private func companionMainContent(
        _ presentation: RichPopoverPresentation
    ) -> some View {
        switch presentation.contentState {
        case .loading:
            VStack(
                alignment: .leading,
                spacing: TokenboardSurfaceMetrics.companionContentSpacing
            ) {
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
        case let .failed(message):
            VStack(
                alignment: .leading,
                spacing: TokenboardSurfaceMetrics.companionContentSpacing
            ) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") {
                    model.openSettings()
                    dismiss()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        case .ready:
            readyDetailsContent(presentation, compactForCompanion: true)
        }
    }

    private func header(
        _ presentation: RichPopoverPresentation,
        refreshPresentation: RichPopoverRefreshPresentation,
        overArtwork: Bool = false
    ) -> some View {
        let controlColor = overArtwork
            ? Color.white.opacity(0.84)
            : Color(nsColor: .secondaryLabelColor)

        return HStack(alignment: .center, spacing: 6) {
            Menu {
                ForEach(RichPopoverPeriodOption.all) { option in
                    Button {
                        Task { await model.select(period: option.period) }
                    } label: {
                        Text(option.title)
                    }
                }
            } label: {
                SurfaceEyebrow(
                    title: presentation.periodTitle,
                    foregroundColor: controlColor
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .tint(controlColor)
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
                .foregroundStyle(controlColor)
                .frame(height: TokenboardSurfaceMetrics.companionHeaderHeight)
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
                    .foregroundStyle(controlColor)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .help(quitAction.title)
            .accessibilityLabel(quitAction.title)
        }
        .frame(height: TokenboardSurfaceMetrics.companionHeaderHeight)
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

            readyDetailsContent(presentation)
        }
    }

    private func readyDetailsContent(
        _ presentation: RichPopoverPresentation,
        compactForCompanion: Bool = false
    ) -> some View {
        let contentSpacing = compactForCompanion
            ? TokenboardSurfaceMetrics.companionContentSpacing
            : TokenboardSurfaceMetrics.popoverContentSpacing
        let chartHeight = compactForCompanion
            ? TokenboardSurfaceMetrics.companionChartHeight
            : 152
        let providerSpacing = compactForCompanion
            ? TokenboardSurfaceMetrics.companionProviderSpacing
            : 10

        return VStack(
            alignment: .leading,
            spacing: contentSpacing
        ) {
            UsageRangePicker(selection: historyRangeBinding)
                .frame(width: TokenboardSurfaceMetrics.popoverContentWidth)

            trendContent(presentation)
                .frame(height: chartHeight)

            if let comparison = presentation.comparison {
                Label(comparison.title, systemImage: comparison.systemImageName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(comparisonColor(presentation.snapshot?.comparison))
                    .accessibilityLabel(comparison.accessibilityTitle)
            }

            workPatternStrip(presentation)

            if presentation.providerRows.isEmpty {
                Text(presentation.emptyMessage ?? "Provider breakdown unavailable")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72, alignment: .center)
            } else {
                VStack(spacing: providerSpacing) {
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
                ZStack(alignment: .top) {
                    UsageTrendChart(
                        snapshot: snapshot,
                        selectedPointID: chartSelectionBinding,
                        compact: true,
                        onHover: { chartSelection.hover($0) },
                        onPin: { pointID in
                            if let pointID {
                                chartSelection.togglePin(pointID)
                            } else {
                                chartSelection.clearAll()
                            }
                        }
                    )
                    if let point = selectedChartPoint(in: snapshot) {
                        usagePointCallout(point, range: snapshot.range)
                            .padding(.top, 3)
                            .allowsHitTesting(false)
                    }
                }
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

    private var chartSelectionBinding: Binding<String?> {
        Binding(
            get: { chartSelection.selectedPointID },
            set: { chartSelection.hover($0) }
        )
    }

    private func selectedChartPoint(in snapshot: UsageHistorySnapshot) -> UsageHistoryPoint? {
        guard let selectedPointID = chartSelection.selectedPointID else { return nil }
        return snapshot.points.first { $0.selectionID == selectedPointID }
    }

    private func usagePointCallout(
        _ point: UsageHistoryPoint,
        range: UsageHistoryRange
    ) -> some View {
        let callout = UsagePointCalloutPresentation.make(
            point: point,
            range: range,
            currency: model.selectedDisplayCurrency
        )
        return VStack(alignment: .leading, spacing: 2) {
            Text(callout.contextTitle)
                .font(.caption.weight(.semibold))
            Text(callout.tokenTitle)
                .font(.callout.weight(.medium))
                .monospacedDigit()
            Text(callout.apiValueTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 190, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(callout.accessibilityTitle)
    }

    private func workPatternStrip(_ presentation: RichPopoverPresentation) -> some View {
        Button {
            model.openHistory(
                range: model.selectedHistoryRange,
                section: .workPatterns
            )
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 4) {
                    Text(presentation.workPatternPreview?.title
                        ?? "WORK PATTERNS · \(presentation.trendRangeTitle)")
                        .font(.caption.weight(.semibold))
                        .tracking(0.35)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                if let preview = presentation.workPatternPreview {
                    HStack(spacing: 0) {
                        ForEach(Array(preview.metrics.enumerated()), id: \.offset) { index, metric in
                            if index > 0 { Divider().frame(height: 24) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(metric.value)
                                    .font(.callout.weight(.semibold))
                                    .monospacedDigit()
                                Text(metric.title)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, index == 0 ? 0 : 9)
                        }
                    }
                } else {
                    Text("Focus patterns are not available yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 7)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityLabel(
            presentation.workPatternPreview?.accessibilityTitle
                ?? "Work patterns are not available yet. Open Work Patterns."
        )
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

    private var companionFooter: some View {
        footer
            .padding(.horizontal, 12)
            .offset(y: TokenboardSurfaceMetrics.companionFooterContentOffset)
            .frame(height: TokenboardSurfaceMetrics.popoverFooterHeight)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(
                        TokenboardSurfaceMetrics.companionFooterSeparatorOpacity
                    ))
                    .frame(height: 1)
            }
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
