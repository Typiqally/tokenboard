import Foundation

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
        let title = stageTitles(for: state.theme)[stage: stage]
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
            accessibilityLabel: accessibilityLabel(
                theme: state.theme,
                variant: variant,
                stage: stage,
                stageTitle: title
            )
        )
    }

    /// A derived presentation for surfaces that re-stage a live one — the
    /// settings shelf's fixed art-directed stage, or a milestone reveal's
    /// from-stage. The stage title (and, unless overridden, the
    /// accessibility label) is recomputed from the canonical tables so a
    /// preview can never show one stage under another stage's name.
    func preview(
        stage: Int,
        scenery: Int = 0,
        progressFraction: Double = 0,
        tokensUntilNextStage: Int64? = nil,
        accessibilityLabel: String? = nil
    ) -> CompanionPresentation {
        let stage = CompanionJourney.clamped(stage: stage)
        let title = Self.stageTitles(for: theme)[stage: stage]
        return CompanionPresentation(
            theme: theme,
            variant: variant,
            stage: stage,
            scenery: scenery,
            seed: seed,
            stageTitle: title,
            progressFraction: progressFraction,
            tokensUntilNextStage: tokensUntilNextStage,
            accessibilityLabel: accessibilityLabel ?? Self.accessibilityLabel(
                theme: theme,
                variant: variant,
                stage: stage,
                stageTitle: title
            )
        )
    }

    private static func accessibilityLabel(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int,
        stageTitle: String
    ) -> String {
        "\(theme.title), \(variant.title), stage \(stage + 1) of \(CompanionJourney.stageCount), \(stageTitle)"
    }

    private static func stageTitles(for theme: CompanionTheme) -> CompanionStageTable<String> {
        switch theme {
        case .none:
            CompanionStageTable(Array(repeating: "", count: CompanionJourney.stageCount))
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
        case .banished:
            ["First shelter", "Gatherer's clearing", "First harvest",
             "Pasture raised", "Roads laid", "River crossing",
             "Trading post", "Market town", "Stone village",
             "First hard winter", "Winter endured", "Thriving township"]
        case .frostpunk:
            ["The Generator", "First tents", "Coal lifeline",
             "Workshop district", "Beacon raised", "Steam hubs",
             "Hothouse harvest", "Industrial city", "Automaton age",
             "Storm watch", "The Great Storm", "New London endures"]
        }
    }
}
