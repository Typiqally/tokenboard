import Foundation
import TokenboardCore

enum CompanionDailyTokenSource {
    static func total(
        from snapshot: UsageHistorySnapshot?,
        at date: Date,
        calendar: Calendar
    ) -> Int64 {
        guard let snapshot,
              snapshot.range == .today,
              snapshot.provider == nil,
              snapshot.currentInterval.contains(date),
              LocalDay(date: snapshot.currentInterval.start, calendar: calendar).value
                == LocalDay(date: date, calendar: calendar).value else { return 0 }
        return max(0, snapshot.breakdown.tokenTotal)
    }
}
