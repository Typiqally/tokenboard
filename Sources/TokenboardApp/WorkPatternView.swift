import Charts
import SwiftUI
import TokenboardCore

private enum WorkHeatmapMode: String, CaseIterable {
    case focus = "Focus time"
    case volume = "Token volume"
    case consistency = "Consistency"
}

struct WorkPatternView: View {
    let snapshot: WorkPatternSnapshot
    let range: UsageHistoryRange
    let provider: Provider?

    @State private var selectedDayID: String?
    @State private var selectedTodayHour: Int?
    @State private var selectedHeatmapID: String?
    @State private var heatmapMode: WorkHeatmapMode = .focus

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if snapshot.isCoveragePartial {
                coverageNotice
            }
            if let insightPresentation {
                insightSection(insightPresentation)
                Divider()
            }
            overview
            Divider()
            activitySection
            if range != .today {
                Divider()
                rhythmSection
            }
            Divider()
            scheduleSection
            Divider()
            estimateCompositionSection
            Text("Activity-backed time represents recorded five-minute slices. Bridged time fills the intervals between slices up to 15 minutes apart; larger gaps and non-AI work are not measured.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var coverageNotice: some View {
        Label {
            Text("Focus timing is available from \(coverageDate). Earlier token totals remain in Usage.")
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Overview", detail: UsageHistoryPresentation.rangeDescription(range))
            HStack(spacing: 0) {
                if range == .today {
                    metric("Est. focus time", duration(snapshot.totalFocusMinutes))
                    metricDivider
                    metric("Focus blocks", "\(snapshot.focusSessionCount)")
                    metricDivider
                    metric("Longest block", duration(snapshot.longestFocusSessionMinutes))
                    metricDivider
                    metric("Tokens", compactTokens(totalTokens))
                } else {
                    metric("Focus / active day", duration(snapshot.averageFocusMinutesPerActiveDay))
                    metricDivider
                    metric("Avg focus block", duration(snapshot.averageFocusSessionMinutes))
                    metricDivider
                    metric("Est. focus time", duration(snapshot.totalFocusMinutes))
                    metricDivider
                    metric("Active days", "\(snapshot.activeDayCount)")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle(
                range == .today ? "Today’s activity" : "Estimated focus by day",
                detail: comparisonTitle
            )
            if range == .today {
                todayChart
                if let selectedTodayCell {
                    detailLine(
                        title: "\(hour(selectedTodayCell.hour))–\(hour((selectedTodayCell.hour + 1) % 24))",
                        detail: "\(duration(selectedTodayCell.focusMinuteCount)) focus · \(ValueFormatter.exactTokens(selectedTodayCell.tokenTotal)) tokens"
                    )
                }
            } else {
                dailyChart
                if let selectedDay {
                    detailLine(
                        title: UsageHistoryPresentation.shortDate(selectedDay.localDay),
                        detail: "\(duration(selectedDay.focusMinuteCount)) focus · \(selectedDay.focusSessionCount) blocks · Peak \(hour(selectedDay.peakHour)) · \(ValueFormatter.exactTokens(selectedDay.tokenTotal)) tokens"
                    )
                }
            }
        }
    }

    private var dailyChart: some View {
        Chart(snapshot.days, id: \.selectionID) { day in
            BarMark(
                x: .value("Day", day.selectionID),
                y: .value("Estimated focus hours", Double(day.focusMinuteCount) / 60)
            )
            .foregroundStyle(
                selectedDayID == nil || selectedDayID == day.selectionID
                    ? Color(nsColor: .secondaryLabelColor)
                    : Color(nsColor: .tertiaryLabelColor).opacity(0.35)
            )
            .cornerRadius(2)
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel()
            }
        }
        .chartXSelection(value: $selectedDayID)
        .frame(height: 155)
        .accessibilityLabel("Daily estimated focus time for the \(UsageHistoryPresentation.rangeDescription(range).lowercased())")
    }

    private var todayChart: some View {
        Chart(todayCells, id: \.hour) { cell in
            BarMark(
                x: .value("Hour", cell.hour),
                y: .value("Estimated focus minutes", cell.focusMinuteCount)
            )
            .foregroundStyle(
                selectedTodayHour == nil || selectedTodayHour == cell.hour
                    ? Color(nsColor: .secondaryLabelColor)
                    : Color(nsColor: .tertiaryLabelColor).opacity(0.35)
            )
            .cornerRadius(2)
        }
        .chartXScale(domain: 0...23)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 23]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) { Text(self.hour(hour)) }
                }
            }
        }
        .chartYAxis(.hidden)
        .chartXSelection(value: $selectedTodayHour)
        .frame(height: 155)
        .accessibilityLabel("Hourly estimated focus time for today")
    }

    private func insightSection(_ presentation: WorkPatternInsightPresentation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Your pattern", detail: "Neutral observations")
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(presentation.rows.enumerated()), id: \.offset) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: insightIcon(row.kind))
                            .foregroundStyle(row.isLearning ? .tertiary : .secondary)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.callout.weight(.medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(row.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                    if index < presentation.rows.count - 1 {
                        Divider().padding(.leading, 28)
                    }
                }
            }
        }
    }

    private var rhythmSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                sectionTitle("Weekly rhythm", detail: "Local time")
                Spacer()
                Picker("Heatmap metric", selection: $heatmapMode) {
                    ForEach(WorkHeatmapMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)
            }
            heatmap
            if let selectedHeatmapCell {
                detailLine(
                    title: "\(UsageHistoryPresentation.weekdayTitle(selectedHeatmapCell.weekday)) at \(hour(selectedHeatmapCell.hour))",
                    detail: "\(ValueFormatter.exactTokens(selectedHeatmapCell.tokenTotal)) tokens · \(duration(selectedHeatmapCell.focusMinuteCount)) focus · Active \(selectedHeatmapCell.activeOccurrenceCount) of \(selectedHeatmapCell.eligibleOccurrenceCount) times"
                )
            }
            HStack(spacing: 0) {
                metric(
                    "Peak hour",
                    hour(snapshot.volumePeakHour?.hour),
                    detail: "Highest token volume"
                )
                metricDivider
                metric(
                    "Most consistent hour",
                    hour(snapshot.consistentHour?.hour),
                    detail: consistency(snapshot.consistentHour?.consistency)
                )
                metricDivider
                metric(
                    "Peak weekday",
                    weekday(snapshot.volumePeakWeekday?.weekday),
                    detail: "Highest token volume"
                )
                metricDivider
                metric(
                    "Most consistent day",
                    weekday(snapshot.consistentWeekday?.weekday),
                    detail: consistency(snapshot.consistentWeekday?.consistency)
                )
            }
        }
    }

    private var heatmap: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Color.clear.frame(width: 34, height: 12)
                ForEach(0..<24, id: \.self) { hour in
                    if hour.isMultiple(of: 3) {
                        Text("\(hour)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    } else {
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
            }
            ForEach(WorkWeekday.allCases, id: \.self) { weekday in
                HStack(spacing: 2) {
                    Text(UsageHistoryPresentation.shortWeekdayTitle(weekday))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 34, alignment: .leading)
                    ForEach(cells(for: weekday), id: \.selectionID) { cell in
                        Button {
                            selectedHeatmapID = selectedHeatmapID == cell.selectionID
                                ? nil
                                : cell.selectionID
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(heatmapColor(cell))
                                .overlay {
                                    if selectedHeatmapID == cell.selectionID {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(Color.primary, lineWidth: 1.5)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(heatmapAccessibility(cell))
                    }
                }
            }
        }
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Schedule highlights", detail: nil)
            HStack(spacing: 0) {
                if range == .today {
                    metric("First activity", hour(snapshot.typicalFirstActivityHour))
                    metricDivider
                    metric("Last activity", hour(snapshot.typicalLastActivityHour))
                    metricDivider
                    metric("Longest focus block", duration(snapshot.longestFocusSessionMinutes))
                } else {
                    metric(
                        "Strongest focus window",
                        qualifiedFocusWindow,
                        detail: focusWindowDetail
                    )
                    metricDivider
                    metric(
                        "First activity range",
                        qualifiedMinuteRange(snapshot.firstActivityMinuteRange),
                        detail: scheduleRangeDetail
                    )
                    metricDivider
                    metric(
                        "Last activity range",
                        qualifiedMinuteRange(snapshot.lastActivityMinuteRange),
                        detail: scheduleRangeDetail
                    )
                }
                metricDivider
                metric(
                    "Busiest date",
                    snapshot.busiestDay.map {
                        UsageHistoryPresentation.shortDate($0.localDay)
                    } ?? "—",
                    detail: snapshot.busiestDay.map {
                        "\(ValueFormatter.exactTokens($0.tokenTotal)) tokens"
                    }
                )
            }
        }
    }

    private var estimateCompositionSection: some View {
        let composition = snapshot.estimateComposition
        return VStack(alignment: .leading, spacing: 9) {
            sectionTitle("Estimate makeup", detail: "How focus time was formed")
            HStack(spacing: 0) {
                metric(
                    "Activity-backed",
                    duration(composition.activityBackedMinutes),
                    detail: percentage(composition.activityBackedShare)
                )
                metricDivider
                metric(
                    "Bridged between interactions",
                    duration(composition.bridgedMinutes)
                )
            }
            ProgressView(
                value: Double(composition.activityBackedMinutes),
                total: Double(max(composition.totalMinutes, 1))
            )
            .tint(.accentColor)
            .accessibilityLabel(
                "\(duration(composition.activityBackedMinutes)) activity-backed and \(duration(composition.bridgedMinutes)) bridged between interactions"
            )
        }
    }

    private func sectionTitle(_ title: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.headline)
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(
        _ title: String,
        _ value: String,
        detail: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var metricDivider: some View {
        Divider().frame(height: 46).padding(.horizontal, 10)
    }

    private func detailLine(title: String, detail: String) -> some View {
        HStack(spacing: 7) {
            Text(title).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(.vertical, 5)
    }

    private var totalTokens: Int64 {
        snapshot.days.reduce(0) { $0 + $1.tokenTotal }
    }

    private var selectedDay: WorkPatternDay? {
        guard let selectedDayID else { return nil }
        return snapshot.days.first { $0.selectionID == selectedDayID }
    }

    private var todayCells: [WorkPatternHeatmapCell] {
        snapshot.heatmap.filter { $0.tokenTotal > 0 || $0.eligibleOccurrenceCount > 0 }
            .sorted { $0.hour < $1.hour }
    }

    private var selectedTodayCell: WorkPatternHeatmapCell? {
        guard let selectedTodayHour else { return nil }
        return todayCells.first { $0.hour == selectedTodayHour }
    }

    private var selectedHeatmapCell: WorkPatternHeatmapCell? {
        guard let selectedHeatmapID else { return nil }
        return snapshot.heatmap.first { $0.selectionID == selectedHeatmapID }
    }

    private var comparisonTitle: String? {
        guard let comparison = snapshot.comparison else { return nil }
        if comparison.focusMinuteDelta == 0 { return "No change vs previous range" }
        let direction = comparison.focusMinuteDelta > 0 ? "+" : "−"
        return "\(direction)\(duration(abs(comparison.focusMinuteDelta))) vs previous range"
    }

    private var coverageDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: snapshot.coverageStart)
    }

    private func cells(for weekday: WorkWeekday) -> [WorkPatternHeatmapCell] {
        snapshot.heatmap.filter { $0.weekday == weekday }.sorted { $0.hour < $1.hour }
    }

    private func heatmapColor(_ cell: WorkPatternHeatmapCell) -> Color {
        let value: Double
        switch heatmapMode {
        case .focus:
            let maximum = max(snapshot.heatmap.map(\.focusMinuteCount).max() ?? 0, 1)
            value = Double(cell.focusMinuteCount) / Double(maximum)
        case .volume:
            let maximum = max(snapshot.heatmap.map(\.tokenTotal).max() ?? 0, 1)
            value = Double(cell.tokenTotal) / Double(maximum)
        case .consistency:
            value = NSDecimalNumber(decimal: cell.consistency).doubleValue
        }
        if value == 0 { return Color(nsColor: .quaternaryLabelColor).opacity(0.35) }
        return Color.accentColor.opacity(0.16 + value * 0.76)
    }

    private func heatmapAccessibility(_ cell: WorkPatternHeatmapCell) -> String {
        "\(UsageHistoryPresentation.weekdayTitle(cell.weekday)) at \(hour(cell.hour)), \(ValueFormatter.exactTokens(cell.tokenTotal)) tokens, \(duration(cell.focusMinuteCount)) estimated focus, active \(cell.activeOccurrenceCount) of \(cell.eligibleOccurrenceCount) times"
    }

    private var insightPresentation: WorkPatternInsightPresentation? {
        WorkPatternInsightPresentation.make(snapshot, range: range, provider: provider)
    }

    private var scheduleRangeDetail: String {
        snapshot.activeDayCount >= 4 ? "Middle 50% of active days" : "Needs 4 active days"
    }

    private var qualifiedFocusWindow: String {
        snapshot.activeDayCount >= 3 ? focusWindow(snapshot.strongestFocusWindow) : "—"
    }

    private var focusWindowDetail: String? {
        snapshot.activeDayCount >= 3 ? nil : "Needs 3 active days"
    }

    private func insightIcon(_ kind: WorkPatternInsightKind) -> String {
        switch kind {
        case .rhythm: "clock"
        case .blocks: "rectangle.stack"
        case .aiInteraction: "cpu"
        }
    }

    private func focusWindow(_ value: WorkPatternFocusWindow?) -> String {
        guard let value else { return "—" }
        return "\(hour(value.startHour))–\(hour(value.endHour))"
    }

    private func qualifiedMinuteRange(_ value: WorkPatternMinuteRange?) -> String {
        guard snapshot.activeDayCount >= 4, let value else { return "—" }
        return "\(minute(value.lowerMinuteOfDay))–\(minute(value.upperMinuteOfDay))"
    }

    private func minute(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    private func hour(_ value: Int?) -> String {
        value.map(UsageHistoryPresentation.hourTitle) ?? "—"
    }

    private func weekday(_ value: WorkWeekday?) -> String {
        value.map(UsageHistoryPresentation.shortWeekdayTitle) ?? "—"
    }

    private func roundedMinutes(_ value: Decimal) -> Int {
        let behavior = NSDecimalNumberHandler(
            roundingMode: .plain,
            scale: 0,
            raiseOnExactness: false,
            raiseOnOverflow: false,
            raiseOnUnderflow: false,
            raiseOnDivideByZero: false
        )
        return NSDecimalNumber(decimal: value)
            .rounding(accordingToBehavior: behavior)
            .intValue
    }

    private func duration(_ minutes: Int) -> String {
        ValueFormatter.duration(minutes: minutes)
    }

    private func duration(_ minutes: Decimal?) -> String {
        guard let minutes else { return "—" }
        return duration(roundedMinutes(minutes))
    }

    private func consistency(_ value: Decimal?) -> String {
        guard let value else { return "No activity" }
        let percentage = (NSDecimalNumber(decimal: value).doubleValue * 100).rounded()
        return "\(Int(percentage))% of eligible days"
    }

    private func percentage(_ value: Decimal?) -> String {
        guard let value else { return "No focus activity" }
        let percentage = (NSDecimalNumber(decimal: value).doubleValue * 100).rounded()
        return "\(Int(percentage))% of estimate"
    }

    private func compactTokens(_ value: Int64) -> String {
        UsageHistoryPresentation.axisTitle(value)
    }
}
