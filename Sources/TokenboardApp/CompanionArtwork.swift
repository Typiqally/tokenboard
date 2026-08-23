import AppKit
import SwiftUI

struct CompanionSceneView: View {
    let presentation: CompanionPresentation

    var body: some View {
        GeometryReader { proxy in
            if let scene = CompanionAssetCatalog.scene(
                theme: presentation.theme,
                variant: presentation.variant,
                stage: presentation.stage
            ) {
                ZStack {
                    CompanionAssetImage(
                        resource: scene.backgroundResource,
                        crop: scene.backgroundCrop,
                        usesNearestNeighbor: false
                    )
                    .scaledToFill()
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()

                    ForEach(scene.layers) { layer in
                        CompanionSceneLayerView(layer: layer, sceneSize: proxy.size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
            } else {
                Color.clear
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(presentation.accessibilityLabel)
    }
}

struct CompanionStrip: View {
    let presentation: CompanionPresentation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CompanionSceneView(presentation: presentation)
            .frame(
                width: TokenboardSurfaceMetrics.popoverContentWidth,
                height: TokenboardSurfaceMetrics.companionSceneHeight
            )
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55))
            }
            .contentTransition(.opacity)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.22),
                value: presentation.stage
            )
    }
}

private struct CompanionSceneLayerView: View {
    let layer: CompanionSceneLayer
    let sceneSize: CGSize

    var body: some View {
        let height = sceneSize.height * layer.relativeHeight
        CompanionAssetImage(
            resource: layer.resource,
            crop: layer.crop,
            usesNearestNeighbor: layer.usesNearestNeighbor
        )
        .scaledToFit()
        .frame(height: height)
        .position(
            x: sceneSize.width * layer.horizontalPosition,
            y: sceneSize.height
                - sceneSize.height * layer.bottomOffset
                - height / 2
        )
        .shadow(color: .black.opacity(0.26), radius: 2, y: 2)
    }
}

private struct CompanionAssetImage: View {
    let resource: String
    let crop: CompanionAssetCrop?
    let usesNearestNeighbor: Bool

    var body: some View {
        if let image = CompanionAssetImageStore.image(resource: resource, crop: crop) {
            Image(nsImage: image)
                .resizable()
                .interpolation(usesNearestNeighbor ? .none : .high)
        } else {
            Color(nsColor: .quaternaryLabelColor)
        }
    }
}

@MainActor
private enum CompanionAssetImageStore {
    private static var images: [String: NSImage] = [:]

    static func image(resource: String, crop: CompanionAssetCrop?) -> NSImage? {
        let key = cacheKey(resource: resource, crop: crop)
        if let image = images[key] { return image }
        guard let source = sourceImage(resource: resource) else { return nil }
        let image = crop.flatMap { cropped(source, to: $0) } ?? source
        images[key] = image
        return image
    }

    private static func sourceImage(resource: String) -> NSImage? {
        if let image = images[resource] { return image }
        let bundledURL = Bundle.main.resourceURL?
            .appending(path: "Companions")
            .appending(path: resource)
        #if DEBUG
        let developmentURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/Companions")
            .appending(path: resource)
        let url = bundledURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? developmentURL
        #else
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else { return nil }
        let url = bundledURL
        #endif
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[resource] = image
        return image
    }

    private static func cropped(
        _ image: NSImage,
        to crop: CompanionAssetCrop
    ) -> NSImage? {
        var proposedRect = NSRect(origin: .zero, size: image.size)
        guard let source = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else { return nil }
        let width = CGFloat(source.width)
        let height = CGFloat(source.height)
        let cropRect = CGRect(
            x: width * crop.x,
            y: height * crop.y,
            width: width * crop.width,
            height: height * crop.height
        ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        guard !cropRect.isEmpty,
              let cropped = source.cropping(to: cropRect) else { return nil }
        return NSImage(
            cgImage: cropped,
            size: NSSize(width: cropped.width, height: cropped.height)
        )
    }

    private static func cacheKey(
        resource: String,
        crop: CompanionAssetCrop?
    ) -> String {
        guard let crop else { return resource }
        return [
            resource,
            String(crop.x),
            String(crop.y),
            String(crop.width),
            String(crop.height)
        ].joined(separator: ":")
    }
}

@MainActor
enum CompanionMenuIconRenderer {
    static func image(
        theme: CompanionTheme,
        variant: CompanionVariant,
        stage: Int
    ) -> NSImage {
        if let layer = CompanionAssetCatalog.menuIconLayer(
            theme: theme,
            variant: variant,
            stage: stage
        ), let source = CompanionAssetImageStore.image(
            resource: layer.resource,
            crop: layer.crop
        ) {
            return templateImage(from: source)
        }

        let symbolName = switch theme {
        case .none: "circle"
        case .pokemon: "pawprint.fill"
        case .tree: "tree.fill"
        case .tower: "building.2.fill"
        case .oldSchoolRuneScape: "figure.walk"
        case .ageOfEmpiresII: "building.columns.fill"
        }
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        symbol.size = NSSize(width: 18, height: 18)
        symbol.isTemplate = true
        return symbol
    }

    private static func templateImage(from source: NSImage) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { destination in
            let size = source.size
            guard size.width > 0, size.height > 0 else { return false }
            let scale = min(destination.width / size.width, destination.height / size.height)
            let drawSize = NSSize(width: size.width * scale, height: size.height * scale)
            let drawRect = NSRect(
                x: destination.midX - drawSize.width / 2,
                y: destination.midY - drawSize.height / 2,
                width: drawSize.width,
                height: drawSize.height
            )
            NSGraphicsContext.current?.imageInterpolation = .high
            source.draw(
                in: drawRect,
                from: .zero,
                operation: .sourceOver,
                fraction: 1
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
