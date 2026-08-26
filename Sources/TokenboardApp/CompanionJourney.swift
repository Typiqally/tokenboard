import Foundation
import TokenboardCore

enum CompanionTheme: String, CaseIterable, Identifiable, Sendable {
    case none
    case pokemon
    case forest
    case village
    case oldSchoolRuneScape = "old_school_runescape"
    case ageOfEmpiresII = "age_of_empires_ii"
    case minecraft

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "None"
        case .pokemon: "Pokémon"
        case .forest: "Forest"
        case .village: "Village"
        case .oldSchoolRuneScape: "Old School RuneScape"
        case .ageOfEmpiresII: "Age of Empires II"
        case .minecraft: "Minecraft"
        }
    }

    var subtitle: String {
        switch self {
        case .none: "Keep Tokenboard clean and compact"
        case .pokemon: "A starter and its evolution family"
        case .forest: "A lone sapling growing into an ancient pixel forest"
        case .village: "A pixel hamlet rising into a high-rise skyline"
        case .oldSchoolRuneScape: "An adventurer upgrading through classic gear"
        case .ageOfEmpiresII: "Town centers advancing through the ages"
        case .minecraft: "A survivor gearing up from spawn to the End"
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
        case .forest:
            named(["Wildwood"])
        case .village:
            named(["Riverstead"])
        case .oldSchoolRuneScape:
            named(["Ranger"])
        case .ageOfEmpiresII:
            named(["Town Center"])
        case .minecraft:
            named(["Steve"])
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

struct CompanionState: Equatable, Sendable {
    var theme: CompanionTheme
    var showInMenuBar: Bool
    var seed: UInt64

    var isVisible: Bool { theme != .none }
}

struct CompanionPresentation: Equatable, Sendable {
    let theme: CompanionTheme
    let variant: CompanionVariant
    let stage: Int
    /// Today's scenery pick for the stage — the same place on a different
    /// day, rotated deterministically so no plate repeats two days running.
    let scenery: Int
    /// The user's stable companion seed; growing themes lay out their trees
    /// and buildings from it so every install grows a distinct place.
    let seed: UInt64
    let stageTitle: String
    let progressFraction: Double
    let tokensUntilNextStage: Int64?
    let showsMilestone: Bool
    let accessibilityLabel: String

    static func make(
        state: CompanionState,
        dailyTokenTotal: Int64 = 0,
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
        let earnedTokens = max(0, dailyTokenTotal)
        let stage = CompanionJourney.stage(for: earnedTokens)
        let title = stageTitles(for: state.theme)[stage]
        let scenery = CompanionDailyVariantSelector.index(
            key: "\(state.theme.rawValue)/scenery/\(stage)",
            seed: state.seed,
            date: date,
            calendar: calendar,
            variantCount: CompanionAssetCatalog.sceneryCount(for: state.theme)
        )
        return CompanionPresentation(
            theme: state.theme,
            variant: variant,
            stage: stage,
            scenery: scenery,
            seed: state.seed,
            stageTitle: title,
            progressFraction: CompanionJourney.fraction(for: earnedTokens),
            tokensUntilNextStage: CompanionJourney.tokensUntilNextStage(for: earnedTokens),
            showsMilestone: false,
            accessibilityLabel: "\(state.theme.title), \(variant.title), stage \(stage + 1) of \(CompanionJourney.thresholds.count), \(title)"
        )
    }

    private static func stageTitles(for theme: CompanionTheme) -> [String] {
        switch theme {
        case .none:
            Array(repeating: "", count: CompanionJourney.thresholds.count)
        case .pokemon:
            ["First partner", "First steps", "Rookie battles", "Training begins",
             "Second evolution", "Growing stronger", "Proven team", "Seasoned partner",
             "Final evolution", "Battle-hardened", "Victory Road", "Evolution family"]
        case .forest:
            ["Lone sapling", "First saplings", "Young grove", "Grove",
             "Greenwood", "Woodland", "Deep woodland", "Old growth",
             "Elder woods", "Ancient forest", "Primeval forest", "Endless forest"]
        case .village:
            ["First cottage", "Homestead", "Hamlet", "Village",
             "Growing town", "Market town", "Busy town", "City blocks",
             "City rising", "Downtown", "High-rise skyline", "Metropolis"]
        case .oldSchoolRuneScape:
            ["Leather", "Frog-leather", "Studded leather", "Snakeskin",
             "Green d’hide", "Blue d’hide", "Red d’hide", "Black d’hide",
             "Karil’s", "Armadyl", "Crystal", "Masori"]
        case .ageOfEmpiresII:
            ["Dark Age camp", "Dark Age hamlet", "Dark Age town", "Feudal Age",
             "Feudal village", "Feudal town", "Castle Age", "Castle village",
             "Castle town", "Imperial Age", "Imperial city", "Imperial capital"]
        case .minecraft:
            ["Fresh spawn", "Into the woods", "Village life", "Lush caves",
             "Jagged peaks", "Ancient city", "Nether wastes", "Crimson forest",
             "Nether fortress", "Stronghold", "The End", "End city"]
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
        index(
            key: theme.rawValue,
            seed: seed,
            date: date,
            calendar: calendar,
            variantCount: variantCount
        )
    }

    /// Deterministic daily pick from `variantCount` options for any keyed
    /// rotation. Distinct keys rotate independently, so the day's scenery
    /// never correlates with the day's Pokémon family.
    static func index(
        key: String,
        seed: UInt64,
        date: Date,
        calendar: Calendar,
        variantCount: Int
    ) -> Int {
        guard variantCount > 1 else { return 0 }
        let day = dayOrdinal(for: date, calendar: calendar)
        let position = positiveModulo(day, variantCount)
        return permutation(count: variantCount, seed: seed ^ CompanionHash.fnv1a(key))[position]
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
}

struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    /// Uniform value in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ low: Double, _ high: Double) -> Double {
        low + unit() * (high - low)
    }
}
