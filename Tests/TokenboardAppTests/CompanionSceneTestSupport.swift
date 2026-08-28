import Foundation
@testable import TokenboardApp

/// The one place the motion suites build their scenes from: a shared seed,
/// real catalog layers, and the plan and subject builders every test uses.
/// Conforming to the protocol gives a test class the helpers unqualified.
protocol CompanionSceneFixtures {}

extension CompanionSceneFixtures {
    var seed: UInt64 { 0x5EED_C0FF_EE12_3456 }

    func plan(for theme: CompanionTheme, stage: Int) -> CompanionScenePlan {
        CompanionScenePlan.make(
            theme: theme,
            stage: stage,
            seed: seed,
            layers: layers(for: theme, stage: stage)
        )
    }

    func layers(for theme: CompanionTheme, stage: Int) -> [CompanionSceneLayer] {
        guard let variant = CompanionCatalog.variants(for: theme).first else { return [] }
        return CompanionAssetCatalog.scene(
            theme: theme,
            variant: variant,
            stage: stage,
            fraction: 0.5,
            seed: seed
        )?.layers ?? []
    }

    func subject(
        signature: CompanionMotionSignature,
        role: CompanionSubjectRole,
        elapsed: Double,
        horizontalPosition: Double = 0.5,
        relativeHeight: Double = 0.6,
        isMoving: Bool = true,
        attention: CompanionAttention = .none
    ) -> CompanionSubjectMotion {
        CompanionSceneMotion.subject(
            signature: signature,
            role: role,
            index: 0,
            horizontalPosition: horizontalPosition,
            relativeHeight: relativeHeight,
            seed: seed,
            elapsed: elapsed,
            isMoving: isMoving,
            attention: attention
        )
    }
}
