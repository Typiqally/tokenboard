import AppKit
import Foundation

@MainActor
enum CompanionAssetImageStore {
    private static var images: [String: NSImage] = [:]

    static func image(resource: String) -> NSImage? {
        if let image = images[resource] { return image }
        guard let url = resourceURL(resource),
              let image = NSImage(contentsOf: url) else { return nil }
        images[resource] = image
        return image
    }

    /// Width over height of the bundled resource, defaulting to square when
    /// the artwork is unavailable so layout stays stable.
    static func aspectRatio(resource: String) -> Double {
        guard let image = image(resource: resource), image.size.height > 0 else {
            return 1
        }
        return image.size.width / image.size.height
    }

    private static func resourceURL(_ resource: String) -> URL? {
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
        return bundledURL.flatMap {
            FileManager.default.fileExists(atPath: $0.path) ? $0 : nil
        } ?? developmentURL
        #else
        guard let bundledURL,
              FileManager.default.fileExists(atPath: bundledURL.path) else { return nil }
        return bundledURL
        #endif
    }
}
