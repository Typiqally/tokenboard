import Darwin
import Foundation

actor DiscordIPCClient: DiscordPresenceClient {
    private var connection: DiscordSocketConnection?
    private var readTask: Task<Void, Never>?

    func connect(applicationID: String) async throws {
        guard DiscordApplicationConfiguration(applicationID: applicationID) != nil else {
            throw DiscordPresenceClientError.invalidConfiguration
        }
        await disconnect()
        let candidates = DiscordIPCEndpointDiscovery.candidates(
            environment: ProcessInfo.processInfo.environment
        )
        let opened = try await Task.detached(priority: .utility) {
            try DiscordSocketConnection.open(candidates: candidates)
        }.value
        do {
            let handshake = try DiscordIPCFrameCodec.encode(
                opcode: .handshake,
                payload: DiscordRPCMessage.handshake(applicationID: applicationID)
            )
            try await Task.detached(priority: .utility) {
                try opened.send(handshake)
                try opened.awaitReady()
            }.value
        } catch {
            opened.close()
            throw error
        }
        connection = opened
        readTask = Task.detached(priority: .utility) { [weak self, opened] in
            do {
                while !Task.isCancelled {
                    let frame = try opened.readFrame()
                    switch frame.opcode {
                    case .ping:
                        try opened.send(DiscordIPCFrameCodec.encode(
                            opcode: .pong,
                            payload: frame.payload
                        ))
                    case .close:
                        throw DiscordPresenceClientError.connectionFailed
                    case .handshake, .frame, .pong:
                        break
                    }
                }
            } catch {
                // The coordinator reconciles status on app lifecycle events or the next update.
            }
            await self?.connectionEnded(opened)
        }
    }

    func setActivity(_ activity: DiscordPresenceActivity?) async throws {
        guard let connection else { throw DiscordPresenceClientError.discordNotRunning }
        let message = try DiscordRPCMessage.activity(
            activity,
            processID: getpid(),
            nonce: UUID().uuidString.lowercased()
        )
        let frame = try DiscordIPCFrameCodec.encode(opcode: .frame, payload: message)
        try await Task.detached(priority: .utility) {
            try connection.send(frame)
        }.value
    }

    func disconnect() async {
        readTask?.cancel()
        readTask = nil
        connection?.close()
        connection = nil
    }

    private func connectionEnded(_ ended: DiscordSocketConnection) {
        guard connection === ended else { return }
        connection = nil
        readTask = nil
    }
}

private final class DiscordSocketConnection: @unchecked Sendable {
    private let descriptorLock = NSLock()
    private let writeLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func open(candidates: [String]) throws -> DiscordSocketConnection {
        var foundOwnedSocket = false
        for path in candidates {
            var metadata = stat()
            guard Darwin.lstat(path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFSOCK,
                  metadata.st_uid == geteuid() else { continue }
            foundOwnedSocket = true

            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { continue }
            var noSignal: Int32 = 1
            _ = withUnsafePointer(to: &noSignal) {
                setsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_NOSIGPIPE,
                    $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
            guard connect(descriptor: descriptor, path: path) else {
                Darwin.close(descriptor)
                continue
            }
            var peerUserID: uid_t = 0
            var peerGroupID: gid_t = 0
            guard getpeereid(descriptor, &peerUserID, &peerGroupID) == 0,
                  peerUserID == geteuid() else {
                Darwin.close(descriptor)
                continue
            }
            return DiscordSocketConnection(descriptor: descriptor)
        }
        throw foundOwnedSocket
            ? DiscordPresenceClientError.connectionFailed
            : DiscordPresenceClientError.discordNotRunning
    }

    func send(_ data: Data) throws {
        try writeLock.withLock {
            let descriptor = try activeDescriptor()
            try data.withUnsafeBytes { rawBuffer in
                guard var pointer = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.send(descriptor, pointer, remaining, 0)
                    if written < 0, errno == EINTR { continue }
                    guard written > 0 else {
                        throw DiscordPresenceClientError.connectionFailed
                    }
                    remaining -= written
                    pointer = pointer.advanced(by: written)
                }
            }
        }
    }

    func awaitReady() throws {
        for _ in 0..<4 {
            let frame = try readFrame(timeoutMilliseconds: 2_000)
            switch frame.opcode {
            case .ping:
                try send(DiscordIPCFrameCodec.encode(opcode: .pong, payload: frame.payload))
            case .frame:
                let object = try JSONSerialization.jsonObject(with: frame.payload)
                guard let payload = object as? [String: Any],
                      payload["evt"] as? String == "READY" else {
                    throw DiscordPresenceClientError.malformedResponse
                }
                return
            case .close, .handshake, .pong:
                throw DiscordPresenceClientError.malformedResponse
            }
        }
        throw DiscordPresenceClientError.malformedResponse
    }

    func readFrame(timeoutMilliseconds: Int32? = nil) throws -> DiscordIPCFrame {
        let header = try readExactly(8, timeoutMilliseconds: timeoutMilliseconds)
        var buffer = header
        let payloadSize = Int(UInt32(buffer[4])
            | (UInt32(buffer[5]) << 8)
            | (UInt32(buffer[6]) << 16)
            | (UInt32(buffer[7]) << 24))
        guard payloadSize <= DiscordIPCFrameCodec.maximumPayloadSize else {
            throw DiscordPresenceClientError.payloadTooLarge
        }
        buffer.append(try readExactly(
            payloadSize,
            timeoutMilliseconds: timeoutMilliseconds
        ))
        let frames = try DiscordIPCFrameCodec.decodeAvailableFrames(from: &buffer)
        guard frames.count == 1, buffer.isEmpty, let frame = frames.first else {
            throw DiscordPresenceClientError.malformedResponse
        }
        return frame
    }

    func close() {
        writeLock.withLock {
            let descriptor = descriptorLock.withLock { () -> Int32 in
                let current = self.descriptor
                self.descriptor = -1
                return current
            }
            guard descriptor >= 0 else { return }
            _ = Darwin.shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
    }

    private func readExactly(
        _ count: Int,
        timeoutMilliseconds: Int32?
    ) throws -> Data {
        guard count > 0 else { return Data() }
        let descriptor = try activeDescriptor()
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while offset < count {
                if let timeoutMilliseconds {
                    var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                    let pollResult = Darwin.poll(&item, 1, timeoutMilliseconds)
                    guard pollResult > 0, item.revents & Int16(POLLIN) != 0 else {
                        throw DiscordPresenceClientError.connectionFailed
                    }
                }
                let received = Darwin.recv(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    count - offset,
                    0
                )
                if received < 0, errno == EINTR { continue }
                guard received > 0 else {
                    throw DiscordPresenceClientError.connectionFailed
                }
                offset += received
            }
        }
        return result
    }

    private func activeDescriptor() throws -> Int32 {
        let current = descriptorLock.withLock { descriptor }
        guard current >= 0 else { throw DiscordPresenceClientError.connectionFailed }
        return current
    }

    private static func connect(descriptor: Int32, path: String) -> Bool {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return false }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    descriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                ) == 0
            }
        }
    }
}
