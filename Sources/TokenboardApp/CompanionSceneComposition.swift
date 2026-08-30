import CoreGraphics
import Foundation

/// Where every part of a scene sits on screen, resolved once per layout.
struct CompanionScenePlacement {
    let layer: CompanionSceneLayer
    let index: Int
    /// The sprite's frame in scene points.
    let rect: CGRect
    /// Windows found in this sprite's own artwork, empty for every theme and
    /// stage that has none.
    let windows: [CompanionWindowCell]
    /// One lighting schedule per window, resolved with the composition so
    /// drawing never re-seeds a generator.
    let windowSchedules: [CompanionWindowLighting.Schedule]

    init(
        layer: CompanionSceneLayer,
        index: Int,
        rect: CGRect,
        windows: [CompanionWindowCell],
        windowSchedules: [CompanionWindowLighting.Schedule] = []
    ) {
        self.layer = layer
        self.index = index
        self.rect = rect
        self.windows = windows
        self.windowSchedules = windowSchedules
    }
}

struct CompanionSceneComposition {
    let asset: CompanionSceneAsset?
    /// The plan with its seeded constants already drawn; frames advance only
    /// time from here.
    let resolvedPlan: CompanionResolvedScenePlan
    let placements: [CompanionScenePlacement]
    let size: CGSize
    let backgroundRect: CGRect
    /// One art pixel of the generated pixel plates, in scene points.
    let artPixel: CGFloat

    var plan: CompanionScenePlan { resolvedPlan.plan }

    @MainActor
    static func make(
        presentation: CompanionPresentation,
        size: CGSize,
        diagnostics: CompanionDiagnostics = .shared
    ) -> CompanionSceneComposition {
        guard let asset = CompanionAssetCatalog.scene(
            theme: presentation.theme,
            variant: presentation.variant,
            stage: presentation.stage,
            scenery: presentation.scenery,
            fraction: presentation.progressFraction,
            seed: presentation.seed
        ) else {
            if presentation.theme != .none {
                diagnostics.record(.unresolvedScene(
                    theme: presentation.theme,
                    stage: presentation.stage
                ))
            }
            return CompanionSceneComposition(
                asset: nil,
                resolvedPlan: CompanionResolvedScenePlan(plan: .inert),
                placements: [],
                size: size,
                backgroundRect: .zero,
                artPixel: 1
            )
        }

        let backgroundRect = plateRect(
            resource: asset.backgroundResource,
            zoom: asset.backgroundZoom,
            size: size
        )
        let lightsOn = presentation.theme == .village
            && presentation.stage >= CompanionAssetCatalog.villageLitStageThreshold
        let placements = asset.layers.enumerated().map { index, layer in
            let height = size.height * layer.relativeHeight
            let width = height * CompanionAssetImageStore.aspectRatio(resource: layer.resource)
            let centerX = size.width * layer.horizontalPosition
            let bottom = size.height - size.height * layer.bottomOffset
            let windows = lightsOn
                ? CompanionWindowMapStore.windows(resource: layer.resource)
                : []
            return CompanionScenePlacement(
                layer: layer,
                index: index,
                rect: CGRect(
                    x: centerX - width / 2,
                    y: bottom - height,
                    width: width,
                    height: height
                ),
                windows: windows,
                windowSchedules: windows.indices.map { window in
                    CompanionWindowLighting.schedule(
                        index: window,
                        layerID: layer.id,
                        seed: presentation.seed
                    )
                }
            )
        }

        return CompanionSceneComposition(
            asset: asset,
            resolvedPlan: CompanionResolvedScenePlan(
                plan: CompanionScenePlan.make(
                    theme: presentation.theme,
                    stage: presentation.stage,
                    seed: presentation.seed,
                    layers: asset.layers
                )
            ),
            placements: placements,
            size: size,
            backgroundRect: backgroundRect,
            artPixel: max(
                1,
                backgroundRect.width / CompanionAssetCatalog.pixelGridWidth
            )
        )
    }

    /// The background plate filled to the frame and anchored to its bottom
    /// edge, so a frame wider than the plate's aspect trims sky and never the
    /// ground the subjects stand on.
    @MainActor
    private static func plateRect(
        resource: String,
        zoom: Double,
        size: CGSize
    ) -> CGRect {
        let aspect = CompanionAssetImageStore.aspectRatio(resource: resource)
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        let fill = max(size.width / (size.height * aspect), 1)
        let width = size.height * aspect * fill * zoom
        let height = size.height * fill * zoom
        return CGRect(
            x: size.width / 2 - width / 2,
            y: size.height - height,
            width: width,
            height: height
        )
    }
}
