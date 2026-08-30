import Foundation

enum TestRepository {
    static var root: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }
}

let canonicalTestTemporaryDirectory = TestRepository.root.appending(
    path: ".build/test-scratch",
    directoryHint: .isDirectory
)
