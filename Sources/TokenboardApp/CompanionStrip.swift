import AppKit
import SwiftUI

/// The popover's companion band: the scene bleeds edge to edge between two
/// hairlines with soft inset shading, reading as a window cut through the
/// popover surface rather than an inserted card.
struct CompanionStrip: View {
    let presentation: CompanionPresentation
    let isAmbientMotionActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        presentation: CompanionPresentation,
        isAmbientMotionActive: Bool = false
    ) {
        self.presentation = presentation
        self.isAmbientMotionActive = isAmbientMotionActive
    }

    var body: some View {
        CompanionSceneView(
            presentation: presentation,
            isAmbientMotionActive: isAmbientMotionActive
        )
            .accessibilityValue(progressAccessibilityValue)
            .frame(
                width: TokenboardSurfaceMetrics.popoverSize.width,
                height: TokenboardSurfaceMetrics.companionSceneHeight
            )
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()
            .overlay { CompanionStripInsetShading() }
            .overlay(alignment: .bottom) {
                CompanionStripProgressBar(fraction: presentation.progressFraction)
            }
            .overlay(alignment: .top) { hairline }
            .overlay(alignment: .bottom) { hairline }
            .contentTransition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: presentation.stage
            )
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.3),
                value: presentation.progressFraction
            )
    }

    private var progressAccessibilityValue: String {
        presentation.tokensUntilNextStage == nil
            ? "Journey complete"
            : "\(Int((presentation.progressFraction * 100).rounded())) percent to the next scene"
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor).opacity(0.55))
            .frame(height: 1)
    }
}

/// The slim journey-progress line along the band's bottom edge. A soft scrim
/// keeps it readable over bright artwork; artwork itself stays text-free.
private struct CompanionStripProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                LinearGradient(
                    colors: [.black.opacity(0), .black.opacity(0.38)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                // A darkened slot under the track keeps the full runway
                // readable over any artwork — without it the fill reads as
                // a floating streak with no visible end point.
                Rectangle()
                    .fill(.black.opacity(0.35))
                    .frame(height: 3)
                Rectangle()
                    .fill(.white.opacity(0.30))
                    .frame(height: 3)
                Rectangle()
                    .fill(.white.opacity(0.95))
                    .frame(
                        width: proxy.size.width * min(max(fraction, 0), 1),
                        height: 3
                    )
            }
        }
        .frame(height: 14)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct CompanionStripInsetShading: View {
    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [.black.opacity(0.26), .black.opacity(0)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 6)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.18)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 6)
        }
        .allowsHitTesting(false)
    }
}
