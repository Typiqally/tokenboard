import Foundation

func developmentCompanionResourceURL(_ resource: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Resources/Companions")
        .appending(path: resource)
}

/// Reads exact PNG dimensions from IHDR without involving AppKit decoding.
func pngPixelSize(at url: URL) -> (width: Int, height: Int)? {
    guard let data = try? Data(contentsOf: url), data.count > 24 else { return nil }
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard Array(data.prefix(8)) == signature else { return nil }
    func bigEndian(at offset: Int) -> Int {
        data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
    }
    return (bigEndian(at: 16), bigEndian(at: 20))
}
