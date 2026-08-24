import AppKit
import Foundation

/// Finds the windows the village artwork already painted, so the town can
/// switch individual lights without shipping a second set of sprites or
/// guessing where a facade's windows are.
///
/// The generated village sprites are chunky pixel art on a fixed art-pixel
/// grid with a two-colour window palette: a warm lit pane and a cold dark
/// one. Sampling that grid once per sprite recovers the exact window layout,
/// and neighbouring cells are merged so a two-cell-wide window switches as
/// one room instead of two halves.
@MainActor
enum CompanionWindowMapStore {
    /// One art pixel is eight image pixels in the baked village sprites.
    static let artPixelSize = 8

    private static var maps: [String: [CompanionWindowCell]] = [:]

    static func windows(resource: String) -> [CompanionWindowCell] {
        if let cached = maps[resource] { return cached }
        let cells = CompanionAssetImageStore.image(resource: resource)
            .flatMap { detect(in: $0) } ?? []
        maps[resource] = cells
        return cells
    }

    /// Exposed for tests: classification is a pure function of a colour.
    static func classify(red: Double, green: Double, blue: Double) -> CompanionWindowTone? {
        // Lit panes are baked at 255,217,138 and shade down on unlit facades.
        if red >= 0.86, green >= 0.72, green <= 0.90, blue >= 0.40, blue <= 0.66 {
            return .lit
        }
        // Dark panes are baked at 46,58,84.
        if red <= 0.28, green >= 0.14, green <= 0.34, blue >= 0.24, blue <= 0.44,
           blue > red {
            return .dark
        }
        return nil
    }

    private static func detect(in image: NSImage) -> [CompanionWindowCell] {
        guard let representation = bitmap(for: image) else { return [] }
        let pixelWidth = representation.pixelsWide
        let pixelHeight = representation.pixelsHigh
        let columns = pixelWidth / artPixelSize
        let rows = pixelHeight / artPixelSize
        guard columns > 0, rows > 0 else { return [] }

        var tones = [CompanionWindowTone?](repeating: nil, count: columns * rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * artPixelSize + artPixelSize / 2
                let y = row * artPixelSize + artPixelSize / 2
                guard let color = representation
                    .colorAt(x: x, y: y)?
                    .usingColorSpace(.sRGB),
                    color.alphaComponent > 0.5 else { continue }
                tones[row * columns + column] = classify(
                    red: color.redComponent,
                    green: color.greenComponent,
                    blue: color.blueComponent
                )
            }
        }
        return merge(tones: tones, columns: columns, rows: rows)
    }

    /// Groups horizontally and vertically adjacent cells of the same tone into
    /// one window, then normalises each into sprite space.
    private static func merge(
        tones: [CompanionWindowTone?],
        columns: Int,
        rows: Int
    ) -> [CompanionWindowCell] {
        var visited = [Bool](repeating: false, count: tones.count)
        var cells: [CompanionWindowCell] = []

        for row in 0..<rows {
            for column in 0..<columns {
                let start = row * columns + column
                guard !visited[start], let tone = tones[start] else { continue }
                var stack = [(column, row)]
                visited[start] = true
                var minColumn = column, maxColumn = column
                var minRow = row, maxRow = row
                var area = 0

                while let (currentColumn, currentRow) = stack.popLast() {
                    area += 1
                    minColumn = min(minColumn, currentColumn)
                    maxColumn = max(maxColumn, currentColumn)
                    minRow = min(minRow, currentRow)
                    maxRow = max(maxRow, currentRow)
                    let neighbours = [
                        (currentColumn - 1, currentRow), (currentColumn + 1, currentRow),
                        (currentColumn, currentRow - 1), (currentColumn, currentRow + 1)
                    ]
                    for (nextColumn, nextRow) in neighbours {
                        guard nextColumn >= 0, nextColumn < columns,
                              nextRow >= 0, nextRow < rows else { continue }
                        let index = nextRow * columns + nextColumn
                        guard !visited[index], tones[index] == tone else { continue }
                        visited[index] = true
                        stack.append((nextColumn, nextRow))
                    }
                }

                // A window is a small pane. Anything larger is a wall, a roof,
                // or the sprite's own contact shadow and must not be repainted.
                let width = maxColumn - minColumn + 1
                let height = maxRow - minRow + 1
                guard area <= 6, width <= 3, height <= 3 else { continue }

                cells.append(
                    CompanionWindowCell(
                        x: Double(minColumn) / Double(columns),
                        // Bitmap rows run top-down for `colorAt`, matching the
                        // scene's own top-left origin.
                        y: Double(minRow) / Double(rows),
                        width: Double(width) / Double(columns),
                        height: Double(height) / Double(rows),
                        bakedLit: tone == .lit
                    )
                )
            }
        }
        return cells
    }

    private static func bitmap(for image: NSImage) -> NSBitmapImageRep? {
        if let representation = image.representations
            .compactMap({ $0 as? NSBitmapImageRep })
            .first {
            return representation
        }
        return image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))
    }
}

enum CompanionWindowTone: String, Equatable, Sendable {
    case lit
    case dark
}
