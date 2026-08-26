import Foundation

/// One drawable in the scene's shared 2.5D painter order. The background is
/// already baked; transparent subjects and inhabitants are interleaved here.
enum CompanionSceneDepthItem: Equatable, Sendable {
    case placement(index: Int)
    case actor(index: Int)
}

enum CompanionSceneDepth {
    private struct Entry {
        let item: CompanionSceneDepthItem
        let groundY: Double
        let kindOrder: Int
        let sourceOrder: Int
    }

    /// Paints from the far edge of the ground plane toward the viewer.
    /// Subjects win the back side of an exact tie so an actor sharing their
    /// ground line remains legible in front. A perched flier is painted last
    /// because its y-coordinate describes the high perch, not ground depth.
    static func painterOrder(
        placements: [CompanionScenePlacement],
        actors: [CompanionActor]
    ) -> [CompanionSceneDepthItem] {
        let placementEntries = placements.enumerated().map { index, placement in
            Entry(
                item: .placement(index: index),
                groundY: 1 - placement.layer.bottomOffset,
                kindOrder: 0,
                sourceOrder: index
            )
        }
        let actorEntries = actors.enumerated().map { index, actor in
            Entry(
                item: .actor(index: index),
                groundY: actor.pose == .perched ? 2 : actor.y,
                kindOrder: 1,
                sourceOrder: index
            )
        }
        return (placementEntries + actorEntries)
            .sorted { lhs, rhs in
                if lhs.groundY != rhs.groundY { return lhs.groundY < rhs.groundY }
                if lhs.kindOrder != rhs.kindOrder { return lhs.kindOrder < rhs.kindOrder }
                return lhs.sourceOrder < rhs.sourceOrder
            }
            .map(\.item)
    }
}
