import XCTest
@testable import TokenboardApp

/// Reports the per-frame cost of the heaviest scene the app can compose.
/// Deliberately non-gating — `measure` without a baseline never fails — so
/// the number is visible in every test log without making CI flaky; a
/// regression shows up as a jump in the reported average.
final class CompanionSceneFramePerformanceTests: XCTestCase, CompanionSceneFixtures {
    func testHeaviestResolvedPlanFrameCost() {
        // The lit village summit resolves the most emitters, windows, and
        // inhabitants of any theme and stage.
        let resolved = CompanionResolvedScenePlan(plan: plan(for: .village, stage: 11))
        var elapsed = 0.0
        measure {
            for _ in 0..<300 {
                elapsed += CompanionSceneMotion.frameInterval
                _ = resolved.frame(at: elapsed, isMoving: true)
            }
        }
    }
}
