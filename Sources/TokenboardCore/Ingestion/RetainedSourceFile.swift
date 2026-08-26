import Darwin
import Foundation

enum RetainedSourceFileError: Error, Equatable {
    case unsafeSource
    case invalidReadBounds
    case shortRead
}

final class RetainedSourceFile: @unchecked Sendable {
    let descriptor: Int32
    let size: Int64
    let modificationTime: Date

    init(url: URL) throws {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw RetainedSourceFileError.unsafeSource }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              information.st_nlink == 1,
              information.st_size >= 0 else {
            Darwin.close(descriptor)
            throw RetainedSourceFileError.unsafeSource
        }
        self.descriptor = descriptor
        size = information.st_size
        modificationTime = Date(
            timeIntervalSince1970: TimeInterval(information.st_mtimespec.tv_sec)
                + TimeInterval(information.st_mtimespec.tv_nsec) / 1_000_000_000
        )
    }

    deinit {
        Darwin.close(descriptor)
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count >= 0, offset <= size else {
            throw RetainedSourceFileError.invalidReadBounds
        }
        let boundedCount = min(count, Int(size - offset))
        guard boundedCount > 0 else { return Data() }
        var data = Data(count: boundedCount)
        var total = 0
        try data.withUnsafeMutableBytes { bytes in
            while total < boundedCount {
                let result = pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: total),
                    boundedCount - total,
                    off_t(offset + Int64(total))
                )
                guard result > 0 else {
                    if result < 0, errno == EINTR { continue }
                    throw RetainedSourceFileError.shortRead
                }
                total += result
            }
        }
        return data
    }
}
