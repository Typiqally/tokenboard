import CryptoKit
import Darwin
import Foundation

enum BoundedDescriptorReadError: Error, Equatable {
    case invalidByteCount
    case shortRead
    case grew
    case readFailed(Int32)
}

enum BoundedDescriptorRead {
    private static let chunkSize = 64 * 1_024

    static func digest(descriptor: Int32, exactByteCount: Int64) throws -> String {
        var hasher = SHA256()
        try consume(descriptor: descriptor, exactByteCount: exactByteCount) { bytes in
            hasher.update(data: bytes)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func consume(
        descriptor: Int32,
        exactByteCount: Int64,
        body: (Data) throws -> Void
    ) throws {
        guard exactByteCount >= 0 else {
            throw BoundedDescriptorReadError.invalidByteCount
        }
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        var offset: Int64 = 0
        while offset < exactByteCount {
            let remaining = exactByteCount - offset
            let requested = min(buffer.count, Int(remaining))
            let count = pread(descriptor, &buffer, requested, off_t(offset))
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                if count == 0 { throw BoundedDescriptorReadError.shortRead }
                throw BoundedDescriptorReadError.readFailed(errno)
            }
            try body(Data(buffer[0..<count]))
            offset += Int64(count)
        }

        var probe: UInt8 = 0
        while true {
            let count = pread(descriptor, &probe, 1, off_t(exactByteCount))
            if count < 0, errno == EINTR { continue }
            if count > 0 { throw BoundedDescriptorReadError.grew }
            if count == 0 { return }
            throw BoundedDescriptorReadError.readFailed(errno)
        }
    }
}
