import XCTest
@testable import TokenboardApp

/// Golden-frame pins captured from the motion system before the resolve-once
/// refactor. Every value below was produced by the shipping implementation;
/// the refactor must reproduce them bit-for-bit (within float tolerance).
///
/// The pins cover the per-frame heavy math — particles, shadow bands, glows,
/// actors, and attention — as order-weighted checksums plus exact counts, so
/// any reordering, re-seeding, or constant drift fails loudly. Wash and
/// background motion are deliberately not checksummed: they move verbatim and
/// the existing still/wash behavioral tests pin them directly.
///
/// Regenerating (only for a deliberate visual change): temporarily restore
/// the capture harness from this file's git history, run it with
/// `swift test --filter CompanionSceneFramePinCaptureTests`, and replace the
/// `expected` table with its output.
enum CompanionFramePinMatrix {
    static let themes: [CompanionTheme] = [
        .pokemon, .forest, .village, .oldSchoolRuneScape, .ageOfEmpiresII, .minecraft
    ]
    static let stages: [Int] = [0, 6, 11]
    static let seeds: [UInt64] = [0x5EED_C0FF_EE12_3456, 0x0123_4567_89AB_CDEF]

    struct Sample {
        let index: Int
        let elapsed: Double
        let isMoving: Bool
    }

    static let samples: [Sample] = [
        Sample(index: 0, elapsed: 0.0, isMoving: true),
        Sample(index: 1, elapsed: 8.4, isMoving: true),
        Sample(index: 2, elapsed: 918_273.5, isMoving: true),
        Sample(index: 3, elapsed: 0.0, isMoving: false),
    ]

    static func plan(theme: CompanionTheme, stage: Int, seed: UInt64) -> CompanionScenePlan {
        CompanionScenePlan.make(
            theme: theme,
            stage: stage,
            seed: seed,
            layers: layers(theme: theme, stage: stage, seed: seed)
        )
    }

    private static func layers(theme: CompanionTheme, stage: Int, seed: UInt64) -> [CompanionSceneLayer] {
        guard let variant = CompanionCatalog.variants(for: theme).first else { return [] }
        return CompanionAssetCatalog.scene(
            theme: theme,
            variant: variant,
            stage: stage,
            fraction: 0.5,
            seed: seed
        )?.layers ?? []
    }

    struct Pin {
        let particleCount: Int
        let bandCount: Int
        let glowCount: Int
        let actorCount: Int
        let particleSum: Double
        let bandSum: Double
        let glowSum: Double
        let actorSum: Double
        let attentionSum: Double
    }

    static func pin(of frame: CompanionSceneFrame) -> Pin {
        Pin(
            particleCount: frame.particles.count,
            bandCount: frame.bands.count,
            glowCount: frame.glows.count,
            actorCount: frame.actors.count,
            particleSum: weightedSum(frame.particles, score(of:)),
            bandSum: weightedSum(frame.bands, score(of:)),
            glowSum: weightedSum(frame.glows, score(of:)),
            actorSum: weightedSum(frame.actors, score(of:)),
            attentionSum: weightedSum(frame.attention.positions) { $0 }
        )
    }

    private static func weightedSum<Element>(
        _ elements: [Element],
        _ score: (Element) -> Double
    ) -> Double {
        elements.enumerated().reduce(0) { total, item in
            total + Double(item.offset + 1) * score(item.element)
        }
    }

    /// Deterministic score for enum/struct payloads: the unicode-scalar sum of
    /// the value's textual description. Stable across processes, sensitive to
    /// any case or field change.
    private static func describedScore<Value>(_ value: Value) -> Double {
        Double(String(describing: value).unicodeScalars.reduce(0) { $0 + Int($1.value) })
    }

    private static func score(of particle: CompanionParticle) -> Double {
        particle.x
            + 2 * particle.y
            + 3 * particle.phase
            + 4 * particle.size
            + 5 * particle.opacity
            + 6 * particle.rotation
            + describedScore(particle.shape) * 1e-3
            + describedScore(particle.tint) * 1e-6
            + (particle.snapsToPixelGrid ? 0.5 : 0)
    }

    private static func score(of band: CompanionShadowBand) -> Double {
        band.centerX
            + 2 * band.width
            + 3 * band.skew
            + 4 * band.opacity
            + 5 * band.top
            + 6 * band.bottom
            + describedScore(band.tint) * 1e-6
    }

    private static func score(of glow: CompanionGlow) -> Double {
        glow.x
            + 2 * glow.y
            + 3 * glow.radius
            + 4 * glow.opacity
            + describedScore(glow.tint) * 1e-6
    }

    private static func score(of actor: CompanionActor) -> Double {
        actor.x
            + 2 * actor.y
            + 3 * actor.height
            + 4 * actor.facing
            + 5 * actor.stride
            + 6 * actor.speed
            + 7 * actor.lift
            + 8 * actor.opacity
            + describedScore(actor.pose) * 1e-3
            + describedScore(actor.body) * 1e-4
            + describedScore(actor.tint) * 1e-6
            + describedScore(actor.accent) * 1e-7
            + (actor.snapsToPixelGrid ? 0.5 : 0)
            + (actor.drawsAttention ? 0.25 : 0)
    }
}

struct FramePin {
    let theme: CompanionTheme
    let stage: Int
    let seedIndex: Int
    let sampleIndex: Int
    let particleCount: Int
    let bandCount: Int
    let glowCount: Int
    let actorCount: Int
    let particleSum: Double
    let bandSum: Double
    let glowSum: Double
    let actorSum: Double
    let attentionSum: Double
}

final class CompanionSceneFramePinTests: XCTestCase {
    func testFrameVectorsMatchThePinnedTable() {
        XCTAssertFalse(Self.expected.isEmpty, "the pin table must never be empty")
        var index = 0
        for theme in CompanionFramePinMatrix.themes {
            for stage in CompanionFramePinMatrix.stages {
                for (seedIndex, seed) in CompanionFramePinMatrix.seeds.enumerated() {
                    let plan = CompanionFramePinMatrix.plan(theme: theme, stage: stage, seed: seed)
                    for sample in CompanionFramePinMatrix.samples {
                        let pinned = Self.expected[index]
                        index += 1
                        XCTAssertEqual(pinned.theme, theme)
                        XCTAssertEqual(pinned.stage, stage)
                        XCTAssertEqual(pinned.seedIndex, seedIndex)
                        XCTAssertEqual(pinned.sampleIndex, sample.index)
                        let frame = plan.frame(at: sample.elapsed, isMoving: sample.isMoving)
                        let pin = CompanionFramePinMatrix.pin(of: frame)
                        let label = "\(theme) stage \(stage) seed[\(seedIndex)] sample[\(sample.index)]"
                        XCTAssertEqual(pin.particleCount, pinned.particleCount, label)
                        XCTAssertEqual(pin.bandCount, pinned.bandCount, label)
                        XCTAssertEqual(pin.glowCount, pinned.glowCount, label)
                        XCTAssertEqual(pin.actorCount, pinned.actorCount, label)
                        assertClose(pin.particleSum, pinned.particleSum, label + " particles")
                        assertClose(pin.bandSum, pinned.bandSum, label + " bands")
                        assertClose(pin.glowSum, pinned.glowSum, label + " glows")
                        assertClose(pin.actorSum, pinned.actorSum, label + " actors")
                        assertClose(pin.attentionSum, pinned.attentionSum, label + " attention")
                    }
                }
            }
        }
        XCTAssertEqual(index, Self.expected.count, "every pinned row must be exercised")
    }

    /// Absolute floor for zero-adjacent values plus a relative term sized to
    /// double precision, so libm variation across macOS releases passes while
    /// any operation reordering from a refactor still fails.
    private func assertClose(
        _ actual: Double,
        _ expected: Double,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            actual,
            expected,
            accuracy: 1e-9 + abs(expected) * 1e-12,
            label,
            file: file,
            line: line
        )
    }

    // Captured 2026-08-28 from the pre-resolver implementation. Do not edit by
    // hand; regenerate per the header instructions.
    static let expected: [FramePin] = [
        FramePin(theme: .pokemon, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2743.3492085727266, bandSum: 0.0, glowSum: 0.0, actorSum: 34.207398719754714, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2714.8852268977007, bandSum: 0.0, glowSum: 0.0, actorSum: 34.50890541487003, attentionSum: 0.38463901705055115),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2692.4655935651144, bandSum: 0.0, glowSum: 0.0, actorSum: 41.75303318646962, attentionSum: 0.03908317371795994),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2698.3655824494112, bandSum: 0.0, glowSum: 0.0, actorSum: 32.03821531810829, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2782.3281691900356, bandSum: 0.0, glowSum: 0.0, actorSum: 40.66430966066524, attentionSum: 0.807958901778099),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2688.412116369905, bandSum: 0.0, glowSum: 0.0, actorSum: 38.37665223241981, attentionSum: 0.24260955830799058),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2754.7646057206125, bandSum: 0.0, glowSum: 0.0, actorSum: 30.33625949416534, attentionSum: 0.29450399430991947),
        FramePin(theme: .pokemon, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2815.1207167652765, bandSum: 0.0, glowSum: 0.0, actorSum: 37.53397453964124, attentionSum: -0.17680727696461182),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2743.3492085727266, bandSum: 0.0, glowSum: 0.0, actorSum: 34.207398719754714, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2714.8852268977007, bandSum: 0.0, glowSum: 0.0, actorSum: 34.50890541487003, attentionSum: 0.38463901705055115),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2692.4655935651144, bandSum: 0.0, glowSum: 0.0, actorSum: 41.75303318646962, attentionSum: 0.03908317371795994),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2698.3655824494112, bandSum: 0.0, glowSum: 0.0, actorSum: 32.03821531810829, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2782.3281691900356, bandSum: 0.0, glowSum: 0.0, actorSum: 40.66430966066524, attentionSum: 0.807958901778099),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2688.412116369905, bandSum: 0.0, glowSum: 0.0, actorSum: 38.37665223241981, attentionSum: 0.24260955830799058),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2754.7646057206125, bandSum: 0.0, glowSum: 0.0, actorSum: 30.33625949416534, attentionSum: 0.29450399430991947),
        FramePin(theme: .pokemon, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 18, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 2815.1207167652765, bandSum: 0.0, glowSum: 0.0, actorSum: 37.53397453964124, attentionSum: -0.17680727696461182),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4160.06494404772, bandSum: 0.0, glowSum: 0.0, actorSum: 34.207398719754714, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4180.537135227224, bandSum: 0.0, glowSum: 0.0, actorSum: 34.50890541487003, attentionSum: 0.38463901705055115),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4167.320255196733, bandSum: 0.0, glowSum: 0.0, actorSum: 41.75303318646962, attentionSum: 0.03908317371795994),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4195.47218799219, bandSum: 0.0, glowSum: 0.0, actorSum: 32.03821531810829, attentionSum: 0.36457403295938545),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4540.841877095524, bandSum: 0.0, glowSum: 0.0, actorSum: 40.66430966066524, attentionSum: 0.807958901778099),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4354.606941365904, bandSum: 0.0, glowSum: 0.0, actorSum: 38.37665223241981, attentionSum: 0.24260955830799058),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4476.449375634473, bandSum: 0.0, glowSum: 0.0, actorSum: 30.33625949416534, attentionSum: 0.29450399430991947),
        FramePin(theme: .pokemon, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 24, bandCount: 0, glowCount: 0, actorCount: 1,
            particleSum: 4503.874681560779, bandSum: 0.0, glowSum: 0.0, actorSum: 37.53397453964124, attentionSum: -0.17680727696461182),
        FramePin(theme: .forest, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 23476.03228996715, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 23332.270936842906, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 16364.592791558942, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 23797.83871060152, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 29427.7011722477, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 30082.113461023015, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 30660.77823087116, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 30651.77138020421, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 23476.036579967145, bandSum: 0.0, glowSum: 0.0, actorSum: 228.96174969692674, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 23332.275226842907, bandSum: 0.0, glowSum: 0.0, actorSum: 217.28692781738326, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16364.597081558939, bandSum: 0.0, glowSum: 0.0, actorSum: 226.77966555926594, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 23797.843000601522, bandSum: 0.0, glowSum: 0.0, actorSum: 209.91639558562838, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 29427.705462247697, bandSum: 0.0, glowSum: 0.0, actorSum: 213.0557972004232, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 30082.117751023015, bandSum: 0.0, glowSum: 0.0, actorSum: 213.18790333938426, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 30660.782520871155, bandSum: 0.0, glowSum: 0.0, actorSum: 214.79411855985086, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 26, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 30651.775670204206, bandSum: 0.0, glowSum: 0.0, actorSum: 218.22688016014214, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 27216.565000289407, bandSum: 0.0, glowSum: 0.0, actorSum: 361.49139716107925, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 27102.8690075133, bandSum: 0.0, glowSum: 0.0, actorSum: 354.8456828879274, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 20205.24791101626, bandSum: 0.0, glowSum: 0.0, actorSum: 357.497584517444, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 27480.96497373526, bandSum: 0.0, glowSum: 0.0, actorSum: 343.2672495057194, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 32990.47689416694, bandSum: 0.0, glowSum: 0.0, actorSum: 350.8573090555716, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 33727.92445121588, bandSum: 0.0, glowSum: 0.0, actorSum: 346.349620814147, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 34351.34405647361, bandSum: 0.0, glowSum: 0.0, actorSum: 351.6221936120399, attentionSum: 0.0),
        FramePin(theme: .forest, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 35, bandCount: 0, glowCount: 0, actorCount: 4,
            particleSum: 34238.84086571489, bandSum: 0.0, glowSum: 0.0, actorSum: 364.6072090715288, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1334.8350298246178, bandSum: 9.883199053201922, glowSum: 0.0, actorSum: 715.4416840817029, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1394.0989995986847, bandSum: 10.360471780474649, glowSum: 0.0, actorSum: 717.6407818555178, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1372.5146009768741, bandSum: 12.01388087138513, glowSum: 0.0, actorSum: 743.4929843230498, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1463.5694251433345, bandSum: 10.508199053201922, glowSum: 0.0, actorSum: 665.4957920275884, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1458.9888682768901, bandSum: 11.601067407227193, glowSum: 0.0, actorSum: 709.4058603054439, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1347.0071458918355, bandSum: 12.078340134499921, glowSum: 0.0, actorSum: 766.737728839912, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1426.3421327234541, bandSum: 11.231749225407139, glowSum: 0.0, actorSum: 679.5092889234598, attentionSum: 0.0),
        FramePin(theme: .village, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 12, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 1355.0716761840758, bandSum: 9.726067407227193, glowSum: 0.0, actorSum: 742.0394961562888, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8480.76603398176, bandSum: 9.883199053201922, glowSum: 0.0, actorSum: 712.0608245037745, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8216.224029035404, bandSum: 10.360471780474649, glowSum: 0.0, actorSum: 714.2599222775895, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 7823.393028040213, bandSum: 12.01388087138513, glowSum: 0.0, actorSum: 733.9487557461105, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8739.926122718489, bandSum: 10.508199053201922, glowSum: 0.0, actorSum: 662.11493244966, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8159.602111734027, bandSum: 11.601067407227193, glowSum: 0.0, actorSum: 704.4943050665688, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8134.707165138542, bandSum: 12.078340134499921, glowSum: 0.0, actorSum: 763.5183125819377, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8245.99681476356, bandSum: 11.231749225407139, glowSum: 0.0, actorSum: 674.5977336845848, attentionSum: 0.0),
        FramePin(theme: .village, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 30, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 8456.579673952368, bandSum: 9.726067407227193, glowSum: 0.0, actorSum: 739.1594699676485, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 17101.359191464497, bandSum: 0.0, glowSum: 0.0, actorSum: 268.08970109320353, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16306.809997393877, bandSum: 0.0, glowSum: 0.0, actorSum: 277.6144408369196, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 15970.784419733758, bandSum: 0.0, glowSum: 0.0, actorSum: 281.01409070957595, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16917.49620158437, bandSum: 0.0, glowSum: 0.0, actorSum: 269.147664049332, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16877.200184153495, bandSum: 0.0, glowSum: 0.0, actorSum: 268.8812694603687, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16844.908410636846, bandSum: 0.0, glowSum: 0.0, actorSum: 271.05273303680593, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 17095.61822004602, bandSum: 0.0, glowSum: 0.0, actorSum: 279.5837511210431, attentionSum: 0.0),
        FramePin(theme: .village, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 47, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 16841.55370920066, bandSum: 0.0, glowSum: 0.0, actorSum: 280.77247176284527, attentionSum: 0.0),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 47.213450467719284, bandSum: 8.30760460371712, glowSum: 0.0, actorSum: 550.7067648660608, attentionSum: 3.136),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 56.88073679316613, bandSum: 8.954898721364179, glowSum: 0.0, actorSum: 625.6887648660608, attentionSum: 3.668),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 54.20807688995879, bandSum: 8.423192839014565, glowSum: 0.0, actorSum: 742.8837648660608, attentionSum: 3.2199999999999998),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 56.88073679316613, bandSum: 8.954898721364179, glowSum: 0.0, actorSum: 625.6887648660608, attentionSum: 3.668),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 46.87152019896336, bandSum: 9.4099170851783, glowSum: 0.0, actorSum: 644.3992272143718, attentionSum: 3.4719999999999995),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 59.598248336234235, bandSum: 7.437211202825359, glowSum: 0.0, actorSum: 676.9642272143717, attentionSum: 3.752),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 57.56504094229766, bandSum: 9.525505320475624, glowSum: 0.0, actorSum: 786.0712272143717, attentionSum: 3.752),
        FramePin(theme: .oldSchoolRuneScape, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 6,
            particleSum: 59.598248336234235, bandSum: 7.437211202825359, glowSum: 0.0, actorSum: 676.9642272143717, attentionSum: 3.752),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 47.213450467719284, bandSum: 8.30760460371712, glowSum: 0.0, actorSum: 118.52076456599815, attentionSum: 1.2040000000000002),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 56.88073679316613, bandSum: 8.954898721364179, glowSum: 0.0, actorSum: 115.24676456599815, attentionSum: 1.316),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 54.20807688995879, bandSum: 8.423192839014565, glowSum: 0.0, actorSum: 124.35576456599816, attentionSum: 1.288),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 56.88073679316613, bandSum: 8.954898721364179, glowSum: 0.0, actorSum: 115.24676456599815, attentionSum: 1.316),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 46.87152019896336, bandSum: 9.4099170851783, glowSum: 0.0, actorSum: 96.44103557839162, attentionSum: 1.708),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 59.598248336234235, bandSum: 7.437211202825359, glowSum: 0.0, actorSum: 133.0550355783916, attentionSum: 1.8199999999999998),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 57.56504094229766, bandSum: 9.525505320475624, glowSum: 0.0, actorSum: 134.30403557839162, attentionSum: 1.736),
        FramePin(theme: .oldSchoolRuneScape, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 2, bandCount: 1, glowCount: 0, actorCount: 2,
            particleSum: 59.598248336234235, bandSum: 7.437211202825359, glowSum: 0.0, actorSum: 133.0550355783916, attentionSum: 1.8199999999999998),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 879.3074605418577, bandSum: 0.0, glowSum: 215.6345108870226, actorSum: 118.52076456599815, attentionSum: 1.2040000000000002),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 880.5442847454335, bandSum: 0.0, glowSum: 202.39856152269266, actorSum: 115.24676456599815, attentionSum: 1.316),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 912.6339415269263, bandSum: 0.0, glowSum: 209.07827153075854, actorSum: 124.35576456599816, attentionSum: 1.288),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 880.5442847454335, bandSum: 0.0, glowSum: 202.39856152269266, actorSum: 115.24676456599815, attentionSum: 1.316),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 918.9937239985202, bandSum: 0.0, glowSum: 215.3707625616887, actorSum: 96.44103557839162, attentionSum: 1.708),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 901.9717839402063, bandSum: 0.0, glowSum: 219.80408323833046, actorSum: 133.0550355783916, attentionSum: 1.8199999999999998),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 856.4412671758773, bandSum: 0.0, glowSum: 206.96978191772718, actorSum: 134.30403557839162, attentionSum: 1.736),
        FramePin(theme: .oldSchoolRuneScape, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 12, bandCount: 0, glowCount: 2, actorCount: 2,
            particleSum: 901.9717839402063, bandSum: 0.0, glowSum: 219.80408323833046, actorSum: 133.0550355783916, attentionSum: 1.8199999999999998),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 3923.2103215892193, bandSum: 21.307872444225566, glowSum: 0.0, actorSum: 622.8692018266673, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 3857.191800454003, bandSum: 20.448925075804514, glowSum: 0.0, actorSum: 595.214821528549, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 3880.54981752908, bandSum: 19.46247770737119, glowSum: 0.0, actorSum: 592.7384552010805, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 3944.8588508407656, bandSum: 21.515898760015038, glowSum: 0.0, actorSum: 562.0697381670552, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 4161.249051481933, bandSum: 19.134864217216496, glowSum: 0.0, actorSum: 538.8946742288472, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 4025.8684200333146, bandSum: 20.825916848795444, glowSum: 0.0, actorSum: 587.1245493642282, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 4012.3818319974616, bandSum: 19.839469480366894, glowSum: 0.0, actorSum: 611.1519559708307, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 5,
            particleSum: 4077.110537378453, bandSum: 21.89289053300597, glowSum: 0.0, actorSum: 613.8346592210603, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 3923.2103215892193, bandSum: 21.307872444225566, glowSum: 0.0, actorSum: 1551.485250553058, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 3857.191800454003, bandSum: 20.448925075804514, glowSum: 0.0, actorSum: 1510.4904659654685, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 3880.54981752908, bandSum: 19.46247770737119, glowSum: 0.0, actorSum: 1474.5740872127817, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 3944.8588508407656, bandSum: 21.515898760015038, glowSum: 0.0, actorSum: 1445.305808774438, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 4161.249051481933, bandSum: 19.134864217216496, glowSum: 0.0, actorSum: 1429.6631857602886, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 4025.8684200333146, bandSum: 20.825916848795444, glowSum: 0.0, actorSum: 1560.0404721223256, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 4012.3818319974616, bandSum: 19.839469480366894, glowSum: 0.0, actorSum: 1556.3939798198903, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 8,
            particleSum: 4077.110537378453, bandSum: 21.89289053300597, glowSum: 0.0, actorSum: 1571.790928495923, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 3923.2103215892193, bandSum: 21.307872444225566, glowSum: 0.0, actorSum: 1945.9753721726747, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 3857.191800454003, bandSum: 20.448925075804514, glowSum: 0.0, actorSum: 1900.442277087656, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 3880.54981752908, bandSum: 19.46247770737119, glowSum: 0.0, actorSum: 1817.09758346566, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 3944.8588508407656, bandSum: 21.515898760015038, glowSum: 0.0, actorSum: 1850.0895550304076, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 4161.249051481933, bandSum: 19.134864217216496, glowSum: 0.0, actorSum: 1825.6930206962, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 4025.8684200333146, bandSum: 20.825916848795444, glowSum: 0.0, actorSum: 1969.1524580057114, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 4012.3818319974616, bandSum: 19.839469480366894, glowSum: 0.0, actorSum: 1934.9598882241366, attentionSum: 0.0),
        FramePin(theme: .ageOfEmpiresII, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 23, bandCount: 2, glowCount: 0, actorCount: 9,
            particleSum: 4077.110537378453, bandSum: 21.89289053300597, glowSum: 0.0, actorSum: 1941.0862396680698, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 0, sampleIndex: 0,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 764.1972101242698, bandSum: 0.0, glowSum: 0.0, actorSum: 175.01518379306543, attentionSum: 3.4163655445986287),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 0, sampleIndex: 1,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 843.5993856789753, bandSum: 0.0, glowSum: 0.0, actorSum: 191.7960785041869, attentionSum: 3.6458064146041194),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 0, sampleIndex: 2,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 814.6299214670879, bandSum: 0.0, glowSum: 0.0, actorSum: 184.79468504455502, attentionSum: 3.9848454074881596),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 0, sampleIndex: 3,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 808.2460416545402, bandSum: 0.0, glowSum: 0.0, actorSum: 197.25262374109582, attentionSum: 3.2865006527426575),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 1, sampleIndex: 0,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 977.9306904545435, bandSum: 0.0, glowSum: 0.0, actorSum: 164.81521986526656, attentionSum: 4.278695065505528),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 1, sampleIndex: 1,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 908.3769092398011, bandSum: 0.0, glowSum: 0.0, actorSum: 207.63682787203052, attentionSum: 4.166608222492904),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 1, sampleIndex: 2,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 941.0764937198728, bandSum: 0.0, glowSum: 0.0, actorSum: 194.16079358981716, attentionSum: 3.9762905884162207),
        FramePin(theme: .minecraft, stage: 0, seedIndex: 1, sampleIndex: 3,
            particleCount: 12, bandCount: 0, glowCount: 0, actorCount: 3,
            particleSum: 955.5842378884183, bandSum: 0.0, glowSum: 0.0, actorSum: 211.31509285483577, attentionSum: 3.615194091819666),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 0, sampleIndex: 0,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7050.045138223008, bandSum: 0.0, glowSum: 0.0, actorSum: 145.82842652606683, attentionSum: 1.6975970268012972),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 0, sampleIndex: 1,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7211.45888936054, bandSum: 0.0, glowSum: 0.0, actorSum: 165.78813937261188, attentionSum: 1.8406100601291446),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 0, sampleIndex: 2,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7130.931585314359, bandSum: 0.0, glowSum: 0.0, actorSum: 156.14740696691942, attentionSum: 1.9581604426435983),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 0, sampleIndex: 3,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7403.278016673005, bandSum: 0.0, glowSum: 0.0, actorSum: 164.4708900830001, attentionSum: 1.6138316158499144),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 1, sampleIndex: 0,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7487.666364781133, bandSum: 0.0, glowSum: 0.0, actorSum: 149.7151707778381, attentionSum: 1.9643411302225655),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 1, sampleIndex: 1,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7082.091884528005, bandSum: 0.0, glowSum: 0.0, actorSum: 162.29657153784296, attentionSum: 1.6942267220651555),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 1, sampleIndex: 2,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7048.009007085315, bandSum: 0.0, glowSum: 0.0, actorSum: 161.3373503510074, attentionSum: 1.9013863663162662),
        FramePin(theme: .minecraft, stage: 6, seedIndex: 1, sampleIndex: 3,
            particleCount: 34, bandCount: 0, glowCount: 0, actorCount: 2,
            particleSum: 7217.354532349882, bandSum: 0.0, glowSum: 0.0, actorSum: 159.52150282786855, attentionSum: 1.6608070928484708),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 0, sampleIndex: 0,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2415.9225700233133, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 0, sampleIndex: 1,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2375.9290134544153, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 0, sampleIndex: 2,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2354.1728324294136, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 0, sampleIndex: 3,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2431.941373330284, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 1, sampleIndex: 0,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2153.660252141177, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 1, sampleIndex: 1,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2355.719456597757, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 1, sampleIndex: 2,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2245.703594945331, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
        FramePin(theme: .minecraft, stage: 11, seedIndex: 1, sampleIndex: 3,
            particleCount: 20, bandCount: 0, glowCount: 0, actorCount: 0,
            particleSum: 2362.8179522183605, bandSum: 0.0, glowSum: 0.0, actorSum: 0.0, attentionSum: 0.0),
    ]
}
