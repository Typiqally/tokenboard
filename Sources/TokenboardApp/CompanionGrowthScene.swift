import Foundation

/// How a growing theme's population advances across the journey: the count
/// at each stage start, interpolated within a stage by the progress
/// fraction, so new subjects keep arriving between milestones.
struct CompanionGrowthPlan: Sendable {
    /// Population at the start of each stage.
    let stageCounts: [Int]
    /// Population when the journey completes.
    let finalCount: Int

    init(stageCounts: [Int], finalCount: Int) {
        precondition(
            stageCounts.count == CompanionJourney.stageCount,
            "Growth plan holds \(stageCounts.count) stage counts for \(CompanionJourney.stageCount) stages"
        )
        self.stageCounts = stageCounts
        self.finalCount = finalCount
    }

    func population(stage: Int, fraction: Double) -> Int {
        let stage = min(max(stage, 0), stageCounts.count - 1)
        let fraction = min(max(fraction, 0), 1)
        let lower = Double(stageCounts[stage])
        let upper = Double(
            stage == stageCounts.count - 1 ? finalCount : stageCounts[stage + 1]
        )
        // The epsilon keeps `appearance(of:)` and this floor in agreement:
        // a slot is visible from exactly the progress it appears at, even
        // when the interpolation lands epsilon under a whole number.
        return Int((lower + (upper - lower) * fraction + 1e-9).rounded(.down))
    }

    /// The global journey progress (0...1 across the whole journey) at which
    /// the given slot first becomes visible. Slots that only arrive at the
    /// journey's very end report 1.
    func appearance(of slot: Int) -> Double {
        let target = slot + 1
        guard target > stageCounts[0] else { return 0 }
        let stages = Double(stageCounts.count)
        for stage in 0..<stageCounts.count {
            let lower = stageCounts[stage]
            let upper = stage == stageCounts.count - 1
                ? finalCount
                : stageCounts[stage + 1]
            if target > lower, target <= upper {
                let within = Double(target - lower) / Double(upper - lower)
                return (Double(stage) + within) / stages
            }
        }
        return 1
    }

    /// Global progress for a stage and its inner fraction.
    func globalProgress(stage: Int, fraction: Double) -> Double {
        let lastStage = stageCounts.count - 1
        return (Double(min(max(stage, 0), lastStage)) + min(max(fraction, 0), 1))
            / Double(stageCounts.count)
    }
}

/// One stable spot in a growing scene. Every roll is drawn up front from
/// the user's seed, so a slot keeps its place, species, and proportions
/// for the whole journey while only its maturity advances.
struct CompanionGrowthSlot {
    let index: Int
    let x: Double
    let back: Bool
    let bottomOffset: Double
    let appearance: Double
    let speciesRoll: Double
    let sizeJitter: Double
}

/// Everything one growing pixel world supplies to the shared builder: its
/// plan and slot layout, and what each slot builds — the forest grows trees
/// and the village raises buildings out of the exact same ground.
struct CompanionGrowthSceneSpec {
    let plan: CompanionGrowthPlan
    /// Key of the deterministic slot layout; part of the seeded RNG stream.
    let slotKey: String
    let frontBottom: Double
    let backBottom: Double
    /// A slot matures one sprite level at each of these ages, measured in
    /// global journey progress since it appeared.
    let maturityAges: [Double]
    let layerIDPrefix: String
    let role: CompanionSubjectRole
    /// The sprite family a slot builds, from its frozen rolls.
    let style: (CompanionGrowthSlot) -> String
    /// The maturity cap the current stage allows a slot.
    let cap: (CompanionGrowthSlot) -> Int
    /// Sprite heights in grid cells per style, maturity-level-indexed.
    let cellHeights: [String: [Int]]
    /// On-screen height for a sprite of `cells` grid cells standing in `slot`.
    let relativeHeight: (Int, CompanionGrowthSlot) -> Double
    /// Bundle path for a style at a maturity level.
    let resource: (String, Int) -> String
    let backgroundResource: String
}

/// The one builder behind both growing themes: stable seeded slots appear
/// with the population and mature with age, whatever each slot builds.
enum CompanionGrowthScene {
    static func make(
        spec: CompanionGrowthSceneSpec,
        stage: Int,
        fraction: Double,
        seed: UInt64
    ) -> CompanionSceneAsset {
        let slots = growthSlots(
            plan: spec.plan,
            seed: seed,
            key: spec.slotKey,
            frontBottom: spec.frontBottom,
            backBottom: spec.backBottom
        )
        let population = spec.plan.population(stage: stage, fraction: fraction)
        let progress = spec.plan.globalProgress(stage: stage, fraction: fraction)
        let layers = slots.prefix(population)
            .sorted(by: paintersOrder)
            .compactMap { slot -> CompanionSceneLayer? in
                let style = spec.style(slot)
                let level = maturityLevel(
                    slot: slot,
                    globalProgress: progress,
                    ages: spec.maturityAges,
                    cap: spec.cap(slot)
                )
                // A style/level pair the cell-height table cannot size is a
                // build defect; skip the sprite rather than crash the render.
                guard let heights = spec.cellHeights[style],
                      heights.indices.contains(level) else {
                    CompanionDiagnostics.note(
                        .missingAsset(resource: spec.resource(style, level))
                    )
                    return nil
                }
                return CompanionSceneLayer(
                    id: "\(spec.layerIDPrefix)\(slot.index)",
                    resource: spec.resource(style, level),
                    relativeHeight: spec.relativeHeight(heights[level], slot),
                    horizontalPosition: slot.x,
                    bottomOffset: slot.bottomOffset,
                    // Pixel sprites carry their own dithered contact shadow.
                    castsGroundShadow: false,
                    role: spec.role
                )
            }
        return CompanionSceneAsset(
            backgroundResource: spec.backgroundResource,
            layers: layers
        )
    }

    private static func growthSlots(
        plan: CompanionGrowthPlan,
        seed: UInt64,
        key: String,
        frontBottom: Double,
        backBottom: Double
    ) -> [CompanionGrowthSlot] {
        var rng = SplitMix64(state: seed ^ CompanionHash.fnv1a(key))
        let phase = rng.unit()
        return (0..<plan.finalCount).map { index in
            let golden = (phase + Double(index) * 0.618033988749895)
                .truncatingRemainder(dividingBy: 1)
            let jitter = rng.range(-0.02, 0.02)
            // The founding subject anchors the scene front and center; every
            // later arrival spreads across the ground via the golden-ratio
            // sequence so density stays even as the population grows.
            let isFounder = index == 0
            let x = isFounder
                ? 0.5 + jitter
                : min(max(0.05 + golden * 0.90 + jitter, 0.04), 0.96)
            // Bands alternate deterministically so both depths fill evenly
            // for every seed — the back band is where the village's oldest
            // lots are allowed to rise into high-rises, so it must always
            // hold early arrivals.
            let back = isFounder ? false : index % 2 == 1
            let bottom = back
                ? backBottom + rng.range(-0.012, 0.012)
                : frontBottom + rng.range(-0.015, 0.015)
            return CompanionGrowthSlot(
                index: index,
                x: x,
                back: back,
                bottomOffset: bottom,
                appearance: plan.appearance(of: index),
                speciesRoll: rng.unit(),
                sizeJitter: rng.range(0.94, 1.06)
            )
        }
    }

    /// Sprite maturity for a slot: how many age thresholds it has crossed,
    /// capped by what the current stage allows.
    private static func maturityLevel(
        slot: CompanionGrowthSlot,
        globalProgress: Double,
        ages: [Double],
        cap: Int
    ) -> Int {
        let age = globalProgress - slot.appearance
        let matured = ages.lastIndex(where: { age >= $0 }).map { $0 + 1 } ?? 0
        return min(matured, cap)
    }

    /// Back band first, then front, each deep-to-near so nearer sprites
    /// paint over farther ones.
    private static func paintersOrder(
        _ lhs: CompanionGrowthSlot,
        _ rhs: CompanionGrowthSlot
    ) -> Bool {
        if lhs.back != rhs.back { return lhs.back }
        if lhs.bottomOffset != rhs.bottomOffset { return lhs.bottomOffset > rhs.bottomOffset }
        return lhs.index < rhs.index
    }
}
