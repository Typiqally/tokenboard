import Foundation

/// The once-per-stage milestone reveal's memory: the highest stage already
/// shown today, persisted as one `"day:stage"` string. The journey is daily,
/// so an acknowledgment from any other local day counts for nothing — a new
/// day resets implicitly, and nothing but today's high-water mark is stored.
struct CompanionMilestoneAcknowledgement: Equatable, Sendable {
    /// The acknowledged local day as `LocalDay.value`, e.g. "2026-08-28".
    let day: String
    let stage: Int

    var storageValue: String { "\(day):\(stage)" }

    init(day: String, stage: Int) {
        self.day = day
        self.stage = max(0, stage)
    }

    init?(storageValue: String) {
        guard let separator = storageValue.lastIndex(of: ":") else { return nil }
        let day = String(storageValue[..<separator])
        guard !day.isEmpty,
              let stage = Int(storageValue[storageValue.index(after: separator)...]),
              stage >= 0 else { return nil }
        self.day = day
        self.stage = stage
    }
}

enum CompanionMilestone {
    /// The stage a popover-open reveal starts its crossfade from, or nil
    /// when there is nothing to reveal. A multi-stage jump reveals once,
    /// from the last acknowledged stage; stage 0 is the day's starting
    /// point and never reveals on its own.
    static func revealSourceStage(
        todayStage: Int,
        acknowledged: CompanionMilestoneAcknowledgement?,
        day: String
    ) -> Int? {
        let ackStage = acknowledgedStage(of: acknowledged, on: day)
        guard todayStage > ackStage else { return nil }
        return ackStage
    }

    /// The acknowledgment to persist after showing `todayStage` on `day`:
    /// today's high-water mark, never lowered.
    static func acknowledging(
        todayStage: Int,
        acknowledged: CompanionMilestoneAcknowledgement?,
        day: String
    ) -> CompanionMilestoneAcknowledgement {
        CompanionMilestoneAcknowledgement(
            day: day,
            stage: max(acknowledgedStage(of: acknowledged, on: day), todayStage)
        )
    }

    private static func acknowledgedStage(
        of acknowledged: CompanionMilestoneAcknowledgement?,
        on day: String
    ) -> Int {
        guard let acknowledged, acknowledged.day == day else { return 0 }
        return acknowledged.stage
    }
}
