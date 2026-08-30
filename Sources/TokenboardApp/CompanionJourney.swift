import Foundation

enum CompanionJourney {
    /// Twelve milestones spread linearly to the one-billion summit: ninety
    /// million tokens per stage, with the final stretch rounding up to 1B.
    static let thresholds: [Int64] = [
        0,
        90_000_000,
        180_000_000,
        270_000_000,
        360_000_000,
        450_000_000,
        540_000_000,
        630_000_000,
        720_000_000,
        810_000_000,
        900_000_000,
        1_000_000_000
    ]

    static var stageCount: Int { thresholds.count }

    static var finalStage: Int { thresholds.count - 1 }

    static func clamped(stage: Int) -> Int {
        min(max(stage, 0), finalStage)
    }

    static func stage(for earnedTokens: Int64) -> Int {
        let value = max(0, earnedTokens)
        return thresholds.lastIndex(where: { value >= $0 }) ?? 0
    }

    static func fraction(for earnedTokens: Int64) -> Double {
        let currentStage = stage(for: earnedTokens)
        guard currentStage < thresholds.count - 1 else { return 1 }
        let lower = thresholds[currentStage]
        let upper = thresholds[currentStage + 1]
        let offset = max(0, earnedTokens - lower)
        return min(1, Double(offset) / Double(upper - lower))
    }

    static func tokensUntilNextStage(for earnedTokens: Int64) -> Int64? {
        let currentStage = stage(for: earnedTokens)
        guard currentStage < thresholds.count - 1 else { return nil }
        return max(0, thresholds[currentStage + 1] - max(0, earnedTokens))
    }
}
