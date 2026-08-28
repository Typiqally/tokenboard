import AppKit
import Charts
import SwiftUI
import TokenboardCore

extension Provider {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }

    var brandTileColor: Color {
        switch self {
        case .claudeCode: Color(red: 0.77, green: 0.34, blue: 0.18)
        case .codex: .black
        }
    }
}

enum TokenboardVisualStyle {
    static let pageInset: CGFloat = 20
    static let compactSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 12
    static let dividerOpacity = 0.55
}

struct SurfaceEyebrow: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}

struct ProviderGlyph: View {
    let provider: Provider
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                .fill(provider.brandTileColor)
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(.white.opacity(0.16))
                }
            if let image = ProviderBrandAssets.image(for: provider.brandMark) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .foregroundStyle(.white)
                    .frame(width: size * 0.56, height: size * 0.56)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct UsageRangePicker: NSViewRepresentable {
    @Binding var selection: UsageHistoryRange
    @Environment(\.isEnabled) private var isEnabled

    static func makeNativeControl() -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: UsageHistoryRange.allCases.map(UsageHistoryPresentation.rangeTitle),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
        control.segmentStyle = .rounded
        control.segmentDistribution = .fillEqually
        control.controlSize = .large
        control.selectedSegmentBezelColor = .controlAccentColor
        control.setAccessibilityLabel("Trend range")
        return control
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = Self.makeNativeControl()
        control.target = context.coordinator
        control.action = #selector(Coordinator.changeSelection(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        control.selectedSegment = UsageHistoryRange.allCases.firstIndex(of: selection) ?? 0
        control.isEnabled = isEnabled
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<UsageHistoryRange>

        init(selection: Binding<UsageHistoryRange>) {
            self.selection = selection
        }

        @objc func changeSelection(_ sender: NSSegmentedControl) {
            guard UsageHistoryRange.allCases.indices.contains(sender.selectedSegment) else {
                return
            }
            selection.wrappedValue = UsageHistoryRange.allCases[sender.selectedSegment]
        }
    }
}

struct UsageTrendChart: View {
    let snapshot: UsageHistorySnapshot
    @Binding var selectedPointID: String?
    var compact = false
    var onHover: ((String?) -> Void)?
    var onPin: ((String?) -> Void)?

    var body: some View {
        VStack(spacing: 7) {
            Chart {
                ForEach(snapshot.points, id: \.selectionID) { point in
                    BarMark(
                        x: .value(snapshot.range == .today ? "Hour" : "Day", point.selectionID),
                        y: .value("Tokens", point.tokenTotal)
                    )
                    .foregroundStyle(
                        selectedPointID == nil || selectedPointID == point.selectionID
                            ? Color(nsColor: .secondaryLabelColor)
                            : Color(nsColor: .tertiaryLabelColor).opacity(0.38)
                    )
                    .cornerRadius(2)
                }
                if let selectedPointID {
                    RuleMark(x: .value("Selected point", selectedPointID))
                        .foregroundStyle(Color.accentColor.opacity(0.58))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 2 : 4)) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    if !compact, let tokenTotal = value.as(Int64.self) {
                        AxisValueLabel {
                            Text(UsageHistoryPresentation.axisTitle(tokenTotal))
                        }
                            .font(.caption2)
                            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    }
                }
            }
            .chartXSelection(value: $selectedPointID)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case let .active(location):
                                onHover?(selectionID(
                                    at: location,
                                    proxy: proxy,
                                    geometry: geometry
                                ))
                            case .ended:
                                onHover?(nil)
                            }
                        }
                        .simultaneousGesture(
                            SpatialTapGesture().onEnded { value in
                                onPin?(selectionID(
                                    at: value.location,
                                    proxy: proxy,
                                    geometry: geometry
                                ))
                            }
                        )
                }
            }
            .accessibilityLabel(
                UsageHistoryPresentation.chartAccessibilityLabel(for: snapshot.range)
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: moveSelection(by: 1)
                case .decrement: moveSelection(by: -1)
                @unknown default: break
                }
            }
            .focusable(onPin != nil)
            .onMoveCommand { direction in
                switch direction {
                case .left: moveSelection(by: -1)
                case .right: moveSelection(by: 1)
                default: break
                }
            }
            .onKeyPress(.space) {
                guard let selectedPointID else { return .ignored }
                onPin?(selectedPointID)
                return .handled
            }
            .onKeyPress(.return) {
                guard let selectedPointID else { return .ignored }
                onPin?(selectedPointID)
                return .handled
            }

            HStack {
                Text(UsageHistoryPresentation.axisLabel(
                    snapshot.points.first,
                    range: snapshot.range
                ))
                Spacer()
                Text(UsageHistoryPresentation.axisLabel(
                    snapshot.points[safe: snapshot.points.count / 2],
                    range: snapshot.range
                ))
                Spacer()
                Text(UsageHistoryPresentation.axisLabel(
                    snapshot.points.last,
                    range: snapshot.range
                ))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private func selectionID(
        at location: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> String? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        guard frame.contains(location) else { return nil }
        return proxy.value(atX: location.x - frame.minX, as: String.self)
    }

    private func moveSelection(by offset: Int) {
        guard !snapshot.points.isEmpty else { return }
        let current = selectedPointID.flatMap { selected in
            snapshot.points.firstIndex { $0.selectionID == selected }
        }
        let proposed = (current ?? (offset > 0 ? -1 : snapshot.points.count)) + offset
        let index = min(max(proposed, 0), snapshot.points.count - 1)
        let pointID = snapshot.points[index].selectionID
        selectedPointID = pointID
        onHover?(pointID)
    }

}

extension UsageComparison {
    var trendColor: Color {
        if tokenDelta > 0 { return .green }
        if tokenDelta < 0 { return .orange }
        return .secondary
    }
}

struct ProviderShareRow: View {
    let row: ProviderSharePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                ProviderGlyph(provider: row.provider)
                Text(row.provider.displayName)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 92, alignment: .leading)
                ProgressView(value: Double(row.percentage), total: 100)
                    .progressViewStyle(.linear)
                    .tint(Color(nsColor: .secondaryLabelColor))
                Text("\(row.percentage)%")
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(
                        width: TokenboardSurfaceMetrics.providerPercentageWidth,
                        alignment: .trailing
                    )
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(row.provider.displayName), \(row.percentage) percent. Open filtered history.")
    }
}

struct BreakdownRow: View {
    let title: String
    let tokenTotal: Int64

    var body: some View {
        HStack {
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(ValueFormatter.exactTokens(tokenTotal))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.callout)
        .padding(.vertical, 2)
    }
}

extension UsageHistoryPresentation {
    static func axisLabel(_ point: UsageHistoryPoint?, range: UsageHistoryRange) -> String {
        guard let point else { return "—" }
        guard range == .today, let hourStart = point.hourStart else {
            return shortDate(point.localDay)
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: point.localDay.timeZoneIdentifier)
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: hourStart)
    }

    static func shortDate(_ day: LocalDay?) -> String {
        guard let day else { return "—" }
        let components = day.value.split(separator: "-")
        guard components.count == 3,
              let month = Int(components[1]),
              let date = Int(components[2]) else { return day.value }
        let formatter = DateFormatter()
        formatter.locale = .current
        let symbols = formatter.shortMonthSymbols ?? []
        guard symbols.indices.contains(month - 1) else { return day.value }
        return "\(symbols[month - 1]) \(date)"
    }

    static func apiEquivalentTitle(
        for breakdown: UsageBreakdown,
        currency: DisplayCurrency
    ) -> String {
        guard let converted = CurrencyConverter.convert(
            usd: breakdown.knownAPIEquivalentUSD,
            to: currency,
            rates: breakdown.exchangeRates?.rates
        ) else {
            return "\(currency.rawValue) API equivalent unavailable"
        }
        return "≈ \(ValueFormatter.currency(converted, currency: currency)) API equivalent"
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
