import Foundation
import XCTest
@testable import TokenboardCore

final class LogDiscoveryTests: XCTestCase {
    func testRecursivelyReturnsOnlyRegularJSONLFilesInSortedOrder() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "nested/deeper")
        let hidden = root.appending(path: ".hidden")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let rootLog = root.appending(path: "z.jsonl")
        let nestedLog = nested.appending(path: "A.JSONL")
        let hiddenLog = hidden.appending(path: "hidden.jsonl")
        let textFile = nested.appending(path: "ignored.txt")
        let jsonlDirectory = root.appending(path: "directory.jsonl")
        let symbolicLink = root.appending(path: "linked.jsonl")
        for file in [rootLog, nestedLog, hiddenLog, textFile] {
            try Data("fixture".utf8).write(to: file)
        }
        try FileManager.default.createDirectory(at: jsonlDirectory, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: nestedLog)

        let files = try LogDiscovery().jsonlFiles(under: root)

        XCTAssertEqual(files, [hiddenLog, nestedLog, rootLog].sorted { $0.path < $1.path })
    }
}
