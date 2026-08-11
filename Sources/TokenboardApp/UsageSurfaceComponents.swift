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

    var symbolName: String {
        switch self {
        case .claudeCode: "sparkles"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var symbolColor: Color {
        switch self {
        case .claudeCode: Color(red: 0.77, green: 0.34, blue: 0.18)
        case .codex: Color(nsColor: .labelColor)
        }
    }
}

enum TokenboardVisualStyle {
    static let pageInset: CGFloat = 20
    static let compactSpacing: CGFloat = 8
    static let sectionSpacing: CGFloat = 14
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
                .fill(
                    provider == .claudeCode
                        ? provider.symbolColor
                        : Color(nsColor: .controlBackgroundColor)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                        .strokeBorder(.white.opacity(provider == .claudeCode ? 0.18 : 0.08))
                }
            Image(systemName: provider.symbolName)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(
                    provider == .claudeCode ? .white : Color(nsColor: .labelColor)
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct UsageRangePicker: View {
    @Binding var selection: UsageHistoryRange

    var body: some View {
        Picker("Trend range", selection: $selection) {
            ForEach(UsageHistoryRange.allCases, id: \.rawValue) { range in
                Text(UsageHistoryPresentation.rangeTitle(range)).tag(range)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .tint(.blue)
        .accessibilityLabel("Trend range")
    }
}

struct UsageTrendChart: View {
    let snapshot: UsageHistorySnapshot
    @Binding var selectedDay: String?
    var compact = false

    var body: some View {
        VStack(spacing: 7) {
            Chart(snapshot.points, id: \.localDay.value) { point in
                BarMark(
                    x: .value("Day", point.localDay.value),
                    y: .value("Tokens", point.tokenTotal)
                )
                .foregroundStyle(
                    selectedDay == nil || selectedDay == point.localDay.value
                        ? Color(nsColor: .secondaryLabelColor)
                        : Color(nsColor: .tertiaryLabelColor).opacity(0.45)
                )
                .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 2 : 4)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        .foregroundStyle(Color(nsColor: .separatorColor))
                    if !compact {
                        AxisValueLabel()
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .chartXSelection(value: $selectedDay)
            .accessibilityLabel(
                UsageHistoryPresentation.chartAccessibilityLabel(for: snapshot.range)
            )

            HStack {
                Text(UsageHistoryPresentation.shortDate(snapshot.points.first?.localDay))
                Spacer()
                Text(UsageHistoryPresentation.shortDate(snapshot.points[safe: snapshot.points.count / 2]?.localDay))
                Spacer()
                Text(UsageHistoryPresentation.shortDate(snapshot.points.last?.localDay))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
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
                    .frame(width: 38, alignment: .trailing)
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
