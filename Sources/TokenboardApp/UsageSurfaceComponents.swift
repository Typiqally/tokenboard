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
}

enum TokenboardVisualStyle {
    static let pageInset: CGFloat = 20
    static let sectionSpacing: CGFloat = 16
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
                .foregroundStyle(barColor(for: point.localDay.value))
                .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: compact ? 2 : 4)) {
                    AxisGridLine()
                        .foregroundStyle(Color(nsColor: .separatorColor).opacity(0.65))
                    if !compact {
                        AxisValueLabel()
                            .font(.caption)
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

    private func barColor(for day: String) -> Color {
        guard let selectedDay else {
            return Color(nsColor: .secondaryLabelColor)
        }
        return selectedDay == day
            ? Color.accentColor
            : Color(nsColor: .tertiaryLabelColor).opacity(0.45)
    }
}

struct ProviderShareRow: View {
    let row: ProviderSharePresentation
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: row.provider.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(row.provider.displayName)
                    .font(.body)
                Spacer(minLength: 12)
                Text("\(row.percentage)%")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 4)
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
