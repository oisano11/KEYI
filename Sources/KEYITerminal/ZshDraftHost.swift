import Darwin
import Foundation

struct ZshDraftCapture: Codable {
    let ticketID: String
    let sessionID: String
    let hostPID: Int32
    let shellPID: Int32
    let startSeconds: Int64
    let startMicroseconds: Int64
    let ttyDevice: UInt64
    let processGroup: Int32
    let buffer: String
    let cursor: Int
    let generation: Int
}

struct ZshDraftCommit: Codable {
    let ticketID: String
    let sessionID: String
    let hostPID: Int32
    let shellPID: Int32
    let startSeconds: Int64
    let startMicroseconds: Int64
    let ttyDevice: UInt64
    let processGroup: Int32
    let buffer: String
    let cursor: Int
    let generation: Int
    let leaseID: String
    let leaseDeadlineUnixMicroseconds: Int64
    let translatedText: String
}

struct ZshDraftCommitAcknowledgement: Codable {
    let ticketID: String
    let committed: Bool
}

enum ZshDraftHostError: Error, LocalizedError {
    case unavailable
    case invalidRequest
    case staleSession
    case timeout
    case rejected
    case malformedCapture
    case invalidCapturedBuffer
    case malformedCaptureField(Int)

    var errorDescription: String? {
        switch self {
        case .unavailable: "当前终端草稿不可用。"
        case .invalidRequest: "终端草稿请求无效。"
        case .staleSession: "终端会话或草稿已变化。"
        case .timeout: "终端草稿响应超时。"
        case .rejected: "终端未接受草稿写回。"
        case .malformedCapture: "终端草稿响应字段无效。"
        case .invalidCapturedBuffer: "终端草稿内容或光标元数据无效。"
        case .malformedCaptureField(let field): "终端草稿响应字段 \(field) 无效。"
        }
    }
}

/// Local-only bridge for an active zsh ZLE buffer. Registration files contain
/// process/TTY metadata only; draft text travels through one short-lived FIFO
/// exchange and is never written to disk or logged.
enum ZshDraftHost {
    private struct Session: Codable {
        let id: String
        let shellPID: Int32
        let startSeconds: Int64
        let startMicroseconds: Int64
        let ttyDevice: UInt64
        let processGroup: Int32
        let ttyPath: String
        let requestFIFO: String
    }

    private struct ProcessInfo {
        let pid: Int32
        let parentPID: Int32
        let processGroup: Int32
        let startSeconds: Int64
        let startMicroseconds: Int64
        let ttyDevice: UInt64
        let foregroundGroup: Int32
        let commandName: String
        let hasControllingTTY: Bool
        let isZombie: Bool
    }

    private static let timeoutMilliseconds = 2_500
    private static let maximumLineBytes = 2 * 1_024 * 1_024

    static func register(shellPID: Int32, ttyPath: String) throws -> String {
        guard shellPID > 0, ttyPath.hasPrefix("/dev/") else {
            throw ZshDraftHostError.invalidRequest
        }
        try ensureRoot()
        let table = try processTable()
        guard let shell = table[shellPID], !shell.isZombie, shell.hasControllingTTY,
              shell.processGroup > 0, shell.foregroundGroup == shell.processGroup,
              ttyDevice(at: ttyPath) == shell.ttyDevice else {
            throw ZshDraftHostError.unavailable
        }
        // A new ZLE line is the only active edit buffer for this shell PID.
        // Remove any prior registration left by an interrupted line-finish.
        for previous in try loadSessions()
        where previous.shellPID == shellPID
            && previous.startSeconds == shell.startSeconds
            && previous.startMicroseconds == shell.startMicroseconds {
            try removeSessionFiles(previous)
        }

        let id = UUID().uuidString.lowercased()
        let directory = sessionDirectory(id)
        guard mkdir(directory, mode_t(0o700)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let fifo = directory + "/request.fifo"
        guard mkfifo(fifo, mode_t(0o600)) == 0 else {
            _ = rmdir(directory)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let session = Session(
            id: id,
            shellPID: shellPID,
            startSeconds: shell.startSeconds,
            startMicroseconds: shell.startMicroseconds,
            ttyDevice: shell.ttyDevice,
            processGroup: shell.processGroup,
            ttyPath: ttyPath,
            requestFIFO: fifo
        )
        do {
            try writeSession(session, directory: directory)
        } catch {
            _ = unlink(fifo)
            _ = rmdir(directory)
            throw error
        }

        return [
            session.id,
            session.requestFIFO,
            String(session.shellPID),
            String(session.startSeconds),
            String(session.startMicroseconds),
            String(session.ttyDevice),
            String(session.processGroup)
        ].joined(separator: "\t")
    }

    static func unregister(id: String, callerPID: Int32 = getppid()) throws {
        guard let session = try loadSession(id), session.shellPID == callerPID else {
            throw ZshDraftHostError.staleSession
        }
        try removeSessionFiles(session)
    }

    private static func removeSessionFiles(_ session: Session) throws {
        let id = session.id
        let directory = sessionDirectory(id)
        let replyNames = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
        for name in replyNames where name.hasPrefix("reply-") && name.hasSuffix(".fifo") {
            let path = directory + "/" + name
            var info = stat()
            if lstat(path, &info) == 0,
               info.st_mode & S_IFMT == S_IFIFO,
               info.st_uid == getuid(),
               info.st_mode & 0o077 == 0 {
                _ = unlink(path)
            }
        }
        _ = unlink(session.requestFIFO)
        _ = unlink(directory + "/session.json")
        guard rmdir(directory) == 0 || errno == ENOENT else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func probe(sessionID: String, hostPID: Int32) throws {
        let session = try requireUniqueSession(hostPID: hostPID)
        guard session.id == sessionID else { throw ZshDraftHostError.staleSession }
        try requireForeground(session, hostPID: hostPID)
    }

    static func capture(hostPID: Int32) throws -> ZshDraftCapture {
        let session = try requireUniqueSession(hostPID: hostPID)
        let ticketID = UUID().uuidString.lowercased()
        let response = try exchange(
            session: session,
            message: "CAPTURE\t\(ticketID)\t\(hostPID)\t\(session.id)",
            expectedOperation: "CAPTURE"
        )
        let fields = response.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 12 else { throw ZshDraftHostError.unavailable }
        guard fields[0] == "ACK", fields[1] == "CAPTURE",
              fields[2] == ticketID, fields[3] == session.id else {
            throw ZshDraftHostError.unavailable
        }
        guard let shellPID = Int32(fields[4]) else { throw ZshDraftHostError.malformedCaptureField(4) }
        guard let startSeconds = Int64(fields[5]) else { throw ZshDraftHostError.malformedCaptureField(5) }
        guard let startMicroseconds = Int64(fields[6]) else { throw ZshDraftHostError.malformedCaptureField(6) }
        guard let ttyDevice = UInt64(fields[7]) else { throw ZshDraftHostError.malformedCaptureField(7) }
        guard let processGroup = Int32(fields[8]) else { throw ZshDraftHostError.malformedCaptureField(8) }
        guard let cursor = Int(fields[9]) else { throw ZshDraftHostError.malformedCaptureField(9) }
        guard let generation = Int(fields[10]) else { throw ZshDraftHostError.malformedCaptureField(10) }
        guard let bufferData = Data(base64Encoded: fields[11]) else { throw ZshDraftHostError.malformedCaptureField(11) }
        guard let buffer = String(data: bufferData, encoding: .utf8) else { throw ZshDraftHostError.malformedCaptureField(12) }
        guard shellPID == session.shellPID,
              startSeconds == session.startSeconds,
              startMicroseconds == session.startMicroseconds,
              ttyDevice == session.ttyDevice,
              processGroup == session.processGroup else {
            throw ZshDraftHostError.staleSession
        }
        guard !buffer.isEmpty,
              buffer.utf8.count <= 65_536,
              cursor >= 0,
              cursor <= buffer.unicodeScalars.count else {
            throw ZshDraftHostError.invalidCapturedBuffer
        }
        // The desktop app does not own the terminal's controlling TTY. The
        // ZLE handler runs probe itself before ACK and performs tcgetpgrp.
        guard try requireUniqueSession(hostPID: hostPID).id == session.id else {
            throw ZshDraftHostError.staleSession
        }
        return ZshDraftCapture(
            ticketID: ticketID,
            sessionID: session.id,
            hostPID: hostPID,
            shellPID: shellPID,
            startSeconds: startSeconds,
            startMicroseconds: startMicroseconds,
            ttyDevice: ttyDevice,
            processGroup: processGroup,
            buffer: buffer,
            cursor: cursor,
            generation: generation
        )
    }

    static func commit(_ request: ZshDraftCommit) throws -> ZshDraftCommitAcknowledgement {
        guard !request.translatedText.isEmpty,
              request.translatedText.utf8.count <= 65_536,
              !request.translatedText.contains("\n"),
              !request.translatedText.contains("\r"),
              !request.translatedText.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw ZshDraftHostError.rejected
        }
        guard let session = try loadSession(request.sessionID),
              session.shellPID == request.shellPID,
              session.startSeconds == request.startSeconds,
              session.startMicroseconds == request.startMicroseconds,
              session.ttyDevice == request.ttyDevice,
              session.processGroup == request.processGroup else {
            throw ZshDraftHostError.staleSession
        }
        guard isActiveCommitLease(
            session: session,
            leaseID: request.leaseID,
            deadlineUnixMicroseconds: request.leaseDeadlineUnixMicroseconds
        ) else {
            throw ZshDraftHostError.timeout
        }
        // Final tcgetpgrp is performed from the ZLE callback via probe; this
        // helper is a desktop child and has no controlling terminal.
        guard try requireUniqueSession(hostPID: request.hostPID).id == session.id else {
            throw ZshDraftHostError.staleSession
        }
        let encodedBuffer = Data(request.buffer.utf8).base64EncodedString()
        let encodedTranslation = Data(request.translatedText.utf8).base64EncodedString()
        let message = [
            "COMMIT", request.ticketID, request.sessionID, String(request.hostPID),
            String(request.shellPID), String(request.startSeconds),
            String(request.startMicroseconds), String(request.ttyDevice),
            String(request.processGroup), String(request.cursor),
            String(request.generation), request.leaseID,
            String(request.leaseDeadlineUnixMicroseconds), encodedBuffer, encodedTranslation
        ].joined(separator: "\t")
        let response = try exchange(
            session: session,
            message: message,
            expectedOperation: "COMMIT",
            replyID: request.leaseID
        )
        let fields = response.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 4, fields[0] == "ACK", fields[1] == "COMMIT",
              fields[2] == request.ticketID, fields[3] == "1" else {
            throw ZshDraftHostError.staleSession
        }
        return ZshDraftCommitAcknowledgement(ticketID: request.ticketID, committed: true)
    }

    private static func requireUniqueSession(hostPID: Int32) throws -> Session {
        guard hostPID > 0 else { throw ZshDraftHostError.invalidRequest }
        let table = try processTable()
        let descendants = try descendantPIDs(of: hostPID, table: table)
        let processes = descendants.compactMap { table[$0] }
        let ttyDevices = Set(processes.compactMap { process -> UInt64? in
            process.hasControllingTTY && !process.isZombie ? process.ttyDevice : nil
        })
        guard ttyDevices.count == 1, let onlyTTY = ttyDevices.first else {
            throw ZshDraftHostError.unavailable
        }

        let registrations = try loadSessions()
        let candidates = registrations.filter { session in
            guard descendants.contains(session.shellPID),
                  session.ttyDevice == onlyTTY,
                  let process = table[session.shellPID] else { return false }
            return !process.isZombie
                && process.hasControllingTTY
                && process.startSeconds == session.startSeconds
                && process.startMicroseconds == session.startMicroseconds
                && process.ttyDevice == session.ttyDevice
                && process.processGroup == session.processGroup
                && process.processGroup > 0
                && process.foregroundGroup == session.processGroup
                && isOrdinaryZsh(session.shellPID, under: hostPID, table: table)
                && ttyDevice(at: session.ttyPath) == session.ttyDevice
        }
        guard candidates.count == 1, let session = candidates.first else {
            throw ZshDraftHostError.unavailable
        }
        return session
    }

    private static func isActiveCommitLease(
        session: Session,
        leaseID: String,
        deadlineUnixMicroseconds: Int64
    ) -> Bool {
        guard UUID(uuidString: leaseID) != nil,
              currentUnixMicroseconds() < deadlineUnixMicroseconds else { return false }
        let path = sessionDirectory(session.id) + "/lease-\(leaseID).txt"
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0,
              info.st_size <= 256,
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let contents = String(data: data, encoding: .utf8) else { return false }
        return contents == "\(leaseID)\t\(deadlineUnixMicroseconds)\t1\n"
    }

    private static func currentUnixMicroseconds() -> Int64 {
        var now = timeval()
        guard gettimeofday(&now, nil) == 0 else { return Int64.max }
        return Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_usec)
    }

    private static func requireForeground(_ session: Session, hostPID: Int32) throws {
        let selected = try requireUniqueSession(hostPID: hostPID)
        guard selected.id == session.id else { throw ZshDraftHostError.staleSession }
        let descriptor = open(session.ttyPath, O_RDONLY | O_NOCTTY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw ZshDraftHostError.unavailable }
        defer { _ = close(descriptor) }
        guard tcgetpgrp(descriptor) == session.processGroup else {
            throw ZshDraftHostError.staleSession
        }
    }

    private static func loadSessions() throws -> [Session] {
        try ensureRoot()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        return names.compactMap { name in
            guard UUID(uuidString: name) != nil else { return nil }
            return try? loadSession(name)
        }
    }

    private static func loadSession(_ id: String) throws -> Session? {
        guard UUID(uuidString: id) != nil else { return nil }
        let directory = sessionDirectory(id)
        var directoryInfo = stat()
        guard lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else { return nil }

        let metadataPath = directory + "/session.json"
        var metadataInfo = stat()
        guard lstat(metadataPath, &metadataInfo) == 0,
              metadataInfo.st_mode & S_IFMT == S_IFREG,
              metadataInfo.st_uid == getuid(),
              metadataInfo.st_mode & 0o077 == 0,
              metadataInfo.st_size <= 16_384 else { return nil }
        let fifo = directory + "/request.fifo"
        var fifoInfo = stat()
        guard lstat(fifo, &fifoInfo) == 0,
              fifoInfo.st_mode & S_IFMT == S_IFIFO,
              fifoInfo.st_uid == getuid(),
              fifoInfo.st_mode & 0o077 == 0 else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: metadataPath))
        let session = try JSONDecoder().decode(Session.self, from: data)
        guard session.id == id,
              session.requestFIFO == fifo,
              session.ttyPath.hasPrefix("/dev/"),
              session.shellPID > 0 else { return nil }
        return session
    }

    private static func writeSession(_ session: Session, directory: String) throws {
        let path = directory + "/session.json"
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(descriptor) }
        let data = try JSONEncoder().encode(session)
        try writeAll(data, to: descriptor, deadline: DispatchTime.now().uptimeNanoseconds + 1_000_000_000)
    }

    private static func ensureRoot() throws {
        let path = rootPath
        if mkdir(path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else {
            throw ZshDraftHostError.unavailable
        }
    }

    private static func exchange(
        session: Session,
        message: String,
        expectedOperation: String,
        replyID requestedReplyID: String? = nil
    ) throws -> String {
        let replyID = requestedReplyID ?? UUID().uuidString.lowercased()
        guard UUID(uuidString: replyID) != nil else { throw ZshDraftHostError.invalidRequest }
        let replyFIFO = sessionDirectory(session.id) + "/reply-\(replyID).fifo"
        guard mkfifo(replyFIFO, mode_t(0o600)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { _ = unlink(replyFIFO) }

        let replyDescriptor = open(replyFIFO, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard replyDescriptor >= 0 else { throw ZshDraftHostError.unavailable }
        defer { _ = close(replyDescriptor) }
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeoutMilliseconds) * 1_000_000
        var requestDescriptor: Int32 = -1
        while requestDescriptor < 0 {
            requestDescriptor = open(session.requestFIFO, O_WRONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
            if requestDescriptor >= 0 { break }
            guard errno == ENXIO else { throw ZshDraftHostError.staleSession }
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                throw ZshDraftHostError.timeout
            }
            usleep(10_000)
        }
        guard requestDescriptor >= 0 else { throw ZshDraftHostError.staleSession }
        defer { _ = close(requestDescriptor) }

        let wireMessage = message + "\t" + replyFIFO + "\n"
        try writeAll(Data(wireMessage.utf8), to: requestDescriptor, deadline: deadline)
        let line = try readLine(from: replyDescriptor, deadline: deadline)
        let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3, fields[0] == "ACK", fields[1] == expectedOperation else {
            throw ZshDraftHostError.rejected
        }
        return line
    }

    private static func writeAll(_ data: Data, to descriptor: Int32, deadline: UInt64) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                if written < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    try wait(descriptor, events: Int16(POLLOUT), deadline: deadline)
                    continue
                }
                throw ZshDraftHostError.staleSession
            }
        }
    }

    private static func readLine(from descriptor: Int32, deadline: UInt64) throws -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while data.count <= maximumLineBytes {
            try wait(descriptor, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                if let newline = data.firstIndex(of: 0x0A) {
                    let line = data[..<newline]
                    guard let string = String(data: line, encoding: .utf8) else {
                        throw ZshDraftHostError.rejected
                    }
                    return string
                }
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { continue }
            throw ZshDraftHostError.staleSession
        }
        throw ZshDraftHostError.rejected
    }

    private static func wait(_ descriptor: Int32, events: Int16, deadline: UInt64) throws {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now < deadline else { throw ZshDraftHostError.timeout }
        let milliseconds = Int32(min((deadline - now) / 1_000_000, UInt64(Int32.max)))
        var item = pollfd(fd: descriptor, events: events, revents: 0)
        let result = poll(&item, 1, milliseconds)
        if result == 0 { throw ZshDraftHostError.timeout }
        if result < 0 && errno != EINTR { throw ZshDraftHostError.staleSession }
    }

    private static func processTable() throws -> [Int32: ProcessInfo] {
        var mib = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var byteCount = 0
        let sizeResult = mib.withUnsafeMutableBufferPointer {
            sysctl($0.baseAddress, u_int($0.count), nil, &byteCount, nil, 0)
        }
        guard sizeResult == 0, byteCount > 0 else { throw ZshDraftHostError.unavailable }
        let stride = MemoryLayout<kinfo_proc>.stride
        var entries = [kinfo_proc](repeating: kinfo_proc(), count: byteCount / stride + 16)
        var outputBytes = entries.count * stride
        let result = entries.withUnsafeMutableBytes { bytes in
            mib.withUnsafeMutableBufferPointer {
                sysctl($0.baseAddress, u_int($0.count), bytes.baseAddress, &outputBytes, nil, 0)
            }
        }
        guard result == 0, outputBytes > 0, outputBytes / stride <= entries.count else {
            throw ZshDraftHostError.unavailable
        }
        return entries.prefix(outputBytes / stride).reduce(into: [:]) { table, entry in
            var process = entry.kp_proc
            let extended = entry.kp_eproc
            let start = process.p_starttime
            let commandName = withUnsafePointer(to: &process.p_comm) { pointer in
                String(cString: pointer.withMemoryRebound(to: CChar.self, capacity: 17) { $0 })
            }
            let info = ProcessInfo(
                pid: process.p_pid,
                parentPID: extended.e_ppid,
                processGroup: extended.e_pgid,
                startSeconds: Int64(start.tv_sec),
                startMicroseconds: Int64(start.tv_usec),
                ttyDevice: UInt64(truncatingIfNeeded: extended.e_tdev),
                foregroundGroup: extended.e_tpgid,
                commandName: commandName,
                hasControllingTTY: process.p_flag & P_CONTROLT != 0,
                isZombie: process.p_stat == 5
            )
            if info.pid > 0 { table[info.pid] = info }
        }
    }

    private static func isOrdinaryZsh(
        _ shellPID: Int32,
        under hostPID: Int32,
        table: [Int32: ProcessInfo]
    ) -> Bool {
        guard let shell = table[shellPID],
              shell.commandName == "zsh" || shell.commandName == "-zsh",
              shell.processGroup == shellPID else { return false }
        var parentPID = shell.parentPID
        var depth = 0
        while parentPID != hostPID && depth < 4 {
            guard let parent = table[parentPID],
                  !parent.isZombie,
                  parent.commandName == "login" else { return false }
            parentPID = parent.parentPID
            depth += 1
        }
        return parentPID == hostPID
    }

    private static func descendantPIDs(of rootPID: Int32, table: [Int32: ProcessInfo]) throws -> Set<Int32> {
        guard table[rootPID] != nil else { throw ZshDraftHostError.unavailable }
        var result: Set<Int32> = [rootPID]
        var foundNewProcess = true
        while foundNewProcess {
            foundNewProcess = false
            for process in table.values where !result.contains(process.pid) && result.contains(process.parentPID) {
                result.insert(process.pid)
                foundNewProcess = true
            }
        }
        return result
    }

    private static func ttyDevice(at path: String) -> UInt64? {
        guard path.hasPrefix("/dev/") else { return nil }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
        return UInt64(truncatingIfNeeded: info.st_rdev)
    }

    private static var rootPath: String {
        "/private/tmp/keyi-zsh-draft-\(getuid())"
    }

    private static func sessionDirectory(_ id: String) -> String {
        rootPath + "/" + id
    }
}
