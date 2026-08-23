import Foundation

enum CompanionTheme: String, CaseIterable, Identifiable, Sendable {
    case none
    case pokemon
    case tree
    case tower
    case oldSchoolRuneScape = "old_school_runescape"
    case ageOfEmpiresII = "age_of_empires_ii"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .pokemon: "Pokémon"
        case .tree: "Tree"
        case .tower: "Tower"
        case .oldSchoolRuneScape: "Old School RuneScape"
        case .ageOfEmpiresII: "Age of Empires II"
        }
    }

    var subtitle: String {
        switch self {
        case .none: "Keep Tokenboard clean and compact"
        case .pokemon: "A starter and its evolution family"
        case .tree: "A seedling growing into a landmark tree"
        case .tower: "A small home becoming a city tower"
        case .oldSchoolRuneScape: "An adventurer upgrading through classic gear"
        case .ageOfEmpiresII: "Town centers advancing through the ages"
        }
    }
}

struct CompanionVariant: Equatable, Identifiable, Sendable {
    let id: String
    let title: String
}

enum CompanionCatalog {
    static func variants(for theme: CompanionTheme) -> [CompanionVariant] {
        switch theme {
        case .none:
            []
        case .pokemon:
            named([
                "Bulbasaur", "Charmander", "Squirtle",
                "Chikorita", "Cyndaquil", "Totodile",
                "Treecko", "Torchic", "Mudkip",
                "Turtwig", "Chimchar", "Piplup"
            ])
        case .tree:
            named(["Oak"])
        case .tower:
            named(["City"])
        case .oldSchoolRuneScape:
            named(["Ranger"])
        case .ageOfEmpiresII:
            named(["Town Center"])
        }
    }

    static func variant(
        for theme: CompanionTheme,
        seed: UInt64,
        date: Date,
        calendar: Calendar
    ) -> CompanionVariant? {
        let variants = variants(for: theme)
        guard !variants.isEmpty else { return nil }
        let index = CompanionDailyVariantSelector.index(
            theme: theme,
            seed: seed,
            date: date,
            calendar: calendar,
            variantCount: variants.count
        )
        return variants[index]
    }

    private static func named(_ titles: [String]) -> [CompanionVariant] {
        titles.map { title in
            CompanionVariant(
                id: title.lowercased()
                    .replacingOccurrences(of: " ", with: "-")
                    .replacingOccurrences(of: "-gothic", with: "gothic"),
                title: title
            )
        }
    }
}

enum CompanionJourney {
    static let thresholds: [Int64] = [
        0,
        1_000_000,
        4_000_000,
        16_000_000,
        64_000_000,
        160_000_000,
        400_000_000,
        1_000_000_000
    ]

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

struct CompanionProgress: Equatable, Sendable {
    var earnedTokens: Int64
    var lastObservedLifetimeTotal: Int64
    var lastAcknowledgedStage: Int

    static func activate(at lifetimeTotal: Int64) -> CompanionProgress {
        CompanionProgress(
            earnedTokens: 0,
            lastObservedLifetimeTotal: max(0, lifetimeTotal),
            lastAcknowledgedStage: 0
        )
    }

    var stage: Int { CompanionJourney.stage(for: earnedTokens) }
    var fraction: Double { CompanionJourney.fraction(for: earnedTokens) }
    var hasUnacknowledgedMilestone: Bool { stage > lastAcknowledgedStage }

    func observing(lifetimeTotal: Int64) -> CompanionProgress {
        let observed = max(0, lifetimeTotal)
        guard observed > lastObservedLifetimeTotal else {
            var rebased = self
            rebased.lastObservedLifetimeTotal = observed
            return rebased
        }
        let delta = observed - lastObservedLifetimeTotal
        let (sum, overflow) = earnedTokens.addingReportingOverflow(delta)
        var advanced = self
        advanced.earnedTokens = overflow ? Int64.max : sum
        advanced.lastObservedLifetimeTotal = observed
        return advanced
    }

    func acknowledgingCurrentStage() -> CompanionProgress {
        var acknowledged = self
        acknowledged.lastAcknowledgedStage = stage
        return acknowledged
    }
}

struct CompanionState: Equatable, Sendable {
    var theme: CompanionTheme
    var showInMenuBar: Bool
    var progress: CompanionProgress?
    var seed: UInt64

    var isVisible: Bool { theme != .none }
    var stage: Int { progress?.stage ?? 0 }
    var fraction: Double { progress?.fraction ?? 0 }
}

struct CompanionPresentation: Equatable, Sendable {
    let theme: CompanionTheme
    let variant: CompanionVariant
    let stage: Int
    let stageTitle: String
    let progressFraction: Double
    let tokensUntilNextStage: Int64?
    let showsMilestone: Bool
    let accessibilityLabel: String

    static func make(
        state: CompanionState,
        date: Date,
        calendar: Calendar
    ) -> CompanionPresentation? {
        guard state.isVisible,
              let variant = CompanionCatalog.variant(
                for: state.theme,
                seed: state.seed,
                date: date,
                calendar: calendar
              ) else { return nil }
        let stage = state.stage
        let title = stageTitles(for: state.theme)[stage]
        return CompanionPresentation(
            theme: state.theme,
            variant: variant,
            stage: stage,
            stageTitle: title,
            progressFraction: state.fraction,
            tokensUntilNextStage: state.progress.flatMap {
                CompanionJourney.tokensUntilNextStage(for: $0.earnedTokens)
            },
            showsMilestone: state.progress?.hasUnacknowledgedMilestone == true,
            accessibilityLabel: "\(state.theme.title), \(variant.title), stage \(stage + 1) of 8, \(title)"
        )
    }

    private static func stageTitles(for theme: CompanionTheme) -> [String] {
        switch theme {
        case .none:
            Array(repeating: "", count: 8)
        case .pokemon:
            ["First partner", "First steps", "Training begins", "Growing stronger",
             "Second evolution", "Seasoned partner", "Final evolution", "Evolution family"]
        case .tree:
            ["Seed", "Sprout", "Sapling", "Young tree", "Branching out",
             "Mature tree", "Ancient canopy", "Landmark tree"]
        case .tower:
            ["Small house", "Townhouse", "Apartments", "Mid-rise", "High-rise",
             "Skyline", "City tower", "Skyscraper"]
        case .oldSchoolRuneScape:
            ["Leather", "Studded leather", "Green d’hide", "Blue d’hide",
             "Red d’hide", "Black d’hide", "Armadyl", "Masori"]
        case .ageOfEmpiresII:
            ["Dark Age camp", "Dark Age town", "Feudal Age", "Feudal settlement",
             "Castle Age", "Castle town", "Imperial Age", "Imperial city"]
        }
    }
}

enum CompanionDailyVariantSelector {
    static func index(
        theme: CompanionTheme,
        seed: UInt64,
        date: Date,
        calendar: Calendar,
        variantCount: Int
    ) -> Int {
        guard variantCount > 1 else { return 0 }
        let day = dayOrdinal(for: date, calendar: calendar)
        let position = positiveModulo(day, variantCount)
        return permutation(count: variantCount, seed: seed ^ stableHash(theme.rawValue))[position]
    }

    private static func dayOrdinal(for date: Date, calendar: Calendar) -> Int {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let day = calendar.date(from: components) ?? calendar.startOfDay(for: date)
        let anchor = calendar.date(from: DateComponents(year: 2001, month: 1, day: 1))!
        return calendar.dateComponents([.day], from: anchor, to: day).day ?? 0
    }

    private static func positiveModulo(_ value: Int, _ modulus: Int) -> Int {
        let remainder = value % modulus
        return remainder >= 0 ? remainder : remainder + modulus
    }

    private static func permutation(count: Int, seed: UInt64) -> [Int] {
        var values = Array(0..<count)
        var generator = SplitMix64(state: seed)
        guard count > 1 else { return values }
        for upper in stride(from: count - 1, through: 1, by: -1) {
            let index = Int(generator.next() % UInt64(upper + 1))
            values.swapAt(upper, index)
        }
        return values
    }

    private static func stableHash(_ string: String) -> UInt64 {
        string.utf8.reduce(14_695_981_039_346_656_037) { value, byte in
            (value ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }
}

private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
