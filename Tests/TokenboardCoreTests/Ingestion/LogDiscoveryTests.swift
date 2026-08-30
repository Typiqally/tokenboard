import Foundation
import XCTest
@testable import TokenboardCore

final class LogDiscoveryTests: XCTestCase {
    func testMissingRootIsReportedInsteadOfBecomingAnEmptyInventory() async {
        let missing = canonicalTestTemporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        XCTAssertThrowsError(try LogDiscovery().jsonlFiles(under: missing))
        do {
            try await LogDiscovery().enumerateJSONLFiles(
                under: missing,
                maximumChunkSize: 64
            ) { _ in }
            XCTFail("expected missing root to fail")
        } catch {
            XCTAssertFalse(error is CancellationError)
        }
    }

    func testChunkEnumerationBoundsEveryDeliveryWithoutDroppingFiles() async throws {
        let root = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let expected = Set((0..<130).map { index in
            root.appending(path: "session-\(index).jsonl").standardizedFileURL
        })
        for file in expected { try Data().write(to: file) }
        let recorder = DiscoveryChunkRecorder()

        try await LogDiscovery().enumerateJSONLFiles(
            under: root,
            maximumChunkSize: 64
        ) { chunk in
            await recorder.record(chunk)
        }

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(snapshot.files, expected)
        XCTAssertEqual(snapshot.chunkSizes, [64, 64, 2])
        XCTAssertEqual(snapshot.maximumActiveConsumers, 1)
    }

    func testRecursivelyReturnsOnlyRegularJSONLFilesInSortedOrder() throws {
        let root = canonicalTestTemporaryDirectory.appending(path: UUID().uuidString)
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

private actor DiscoveryChunkRecorder {
    private var files: Set<URL> = []
    private var chunkSizes: [Int] = []
    private var activeConsumers = 0
    private var maximumActiveConsumers = 0

    func record(_ chunk: [URL]) async {
        activeConsumers += 1
        maximumActiveConsumers = max(maximumActiveConsumers, activeConsumers)
        chunkSizes.append(chunk.count)
        files.formUnion(chunk)
        await Task.yield()
        activeConsumers -= 1
    }

    func snapshot() -> (
        files: Set<URL>,
        chunkSizes: [Int],
        maximumActiveConsumers: Int
    ) {
        (files, chunkSizes, maximumActiveConsumers)
    }
}
