import AppKit
import ApplicationServices
import Darwin
import Foundation

struct TerminalZshDraftCapture: Codable {
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

struct TerminalZshDraftCommit: Codable {
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

struct TerminalZshDraftAcknowledgement: Codable {
    let ticketID: String
    let committed: Bool
}

final class ZshDraftFocusObservation: @unchecked Sendable {
    enum Error: Swift.Error { case notificationsUnavailable }

    private let gate = TerminalDraftChangeGate()
    private var observer: AXObserver?
    private var subscriptions: [(AXUIElement, String)] = []
    private var workspaceToken: (any NSObjectProtocol)?

    var isCurrent: Bool { gate.isCurrent }

    func observeInvalidation(_ handler: @escaping @Sendable () -> Void) -> UUID {
        gate.observeInvalidation(handler)
    }

    func removeInvalidationObserver(_ id: UUID) {
        gate.removeInvalidationObserver(id)
    }

    @MainActor
    static func begin(applicationPID: pid_t) throws -> ZshDraftFocusObservation {
        let result = ZshDraftFocusObservation()
        let gate = result.gate
        let center = NSWorkspace.shared.notificationCenter
        var observer: AXObserver?
        guard AXObserverCreate(applicationPID, { _, _, _, context in
            guard let context else { return }
            Unmanaged<TerminalDraftChangeGate>.fromOpaque(context)
                .takeUnretainedValue().invalidate()
        }, &observer) == .success, let observer else {
            throw Error.notificationsUnavailable
        }
        result.observer = observer
        let application = AXUIElementCreateApplication(applicationPID)
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification
        ] {
            guard AXObserverAddNotification(
                observer,
                application,
                notification as CFString,
                Unmanaged.passUnretained(gate).toOpaque()
            ) == .success else {
                result.invalidate()
                throw Error.notificationsUnavailable
            }
            result.subscriptions.append((application, notification))
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        result.workspaceToken = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { notification in
            guard let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  activated.processIdentifier == applicationPID else {
                gate.invalidate()
                return
            }
        }
        return result
    }

    func invalidate() {
        gate.invalidate()
        if let workspaceToken {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken)
            self.workspaceToken = nil
        }
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            for (element, notification) in subscriptions {
                AXObserverRemoveNotification(observer, element, notification as CFString)
            }
            subscriptions.removeAll()
            self.observer = nil
        }
    }

    deinit { invalidate() }
}

private final class ZshDraftCommitLease: @unchecked Sendable {
    let id: String
    let deadlineUnixMicroseconds: Int64
    private let leasePath: String
    private let replyPath: String
    private let lock = NSLock()
    private var active = true

    private init(id: String, deadlineUnixMicroseconds: Int64, directory: String) {
        self.id = id
        self.deadlineUnixMicroseconds = deadlineUnixMicroseconds
        leasePath = directory + "/lease-\(id).txt"
        replyPath = directory + "/reply-\(id).fifo"
    }

    static func create(sessionID: String) throws -> ZshDraftCommitLease {
        guard UUID(uuidString: sessionID) != nil else { throw ZshDraftProcessClient.Failure.unavailable }
        let root = "/private/tmp/keyi-zsh-draft-\(getuid())"
        let directory = root + "/\(sessionID)"
        var rootInfo = stat()
        var directoryInfo = stat()
        guard lstat(root, &rootInfo) == 0,
              rootInfo.st_mode & S_IFMT == S_IFDIR,
              rootInfo.st_uid == getuid(),
              rootInfo.st_mode & 0o077 == 0,
              lstat(directory, &directoryInfo) == 0,
              directoryInfo.st_mode & S_IFMT == S_IFDIR,
              directoryInfo.st_uid == getuid(),
              directoryInfo.st_mode & 0o077 == 0 else {
            throw ZshDraftProcessClient.Failure.unavailable
        }

        var now = timeval()
        guard gettimeofday(&now, nil) == 0 else { throw ZshDraftProcessClient.Failure.unavailable }
        let deadline = Int64(now.tv_sec) * 1_000_000 + Int64(now.tv_usec) + 2_500_000
        let id = UUID().uuidString.lowercased()
        let lease = ZshDraftCommitLease(id: id, deadlineUnixMicroseconds: deadline, directory: directory)
        let descriptor = open(
            lease.leasePath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard descriptor >= 0 else { throw ZshDraftProcessClient.Failure.unavailable }
        let bytes = Data("\(id)\t\(deadline)\t1\n".utf8)
        let writeStatus = bytes.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base.advanced(by: offset), buffer.count - offset)
                if written > 0 { offset += written; continue }
                if written < 0 && errno == EINTR { continue }
                return false
            }
            return true
        }
        let closeStatus = close(descriptor)
        guard writeStatus, closeStatus == 0 else {
            _ = unlink(lease.leasePath)
            throw ZshDraftProcessClient.Failure.unavailable
        }
        return lease
    }

    func revoke() {
        let paths: (String, String)? = lock.withLock {
            guard active else { return nil }
            active = false
            return (leasePath, replyPath)
        }
        guard let paths else { return }
        _ = unlink(paths.0)
        _ = unlink(paths.1)
    }

    deinit { revoke() }
}

final class ZshDraftTicket {
    let capture: TerminalZshDraftCapture
    let focusObservation: ZshDraftFocusObservation

    init(capture: TerminalZshDraftCapture, focusObservation: ZshDraftFocusObservation) {
        self.capture = capture
        self.focusObservation = focusObservation
    }
}

enum ZshDraftProcessClient {
    enum Failure: Error {
        case unavailable
    }

    private final class RunningProcess: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func install(_ process: Process) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.process = process
                return true
            }
        }

        func didStart() {
            let shouldTerminate = lock.withLock { cancelled }
            if shouldTerminate, let process, process.isRunning { process.terminate() }
        }

        func cancel() {
            let process = lock.withLock {
                cancelled = true
                return self.process
            }
            if let process, process.isRunning { process.terminate() }
        }

        func clear() {
            lock.withLock { process = nil }
        }
    }

    static func capture(hostPID: pid_t) async throws -> TerminalZshDraftCapture {
        let data = try await run(arguments: ["zsh-draft", "capture", String(hostPID)])
        guard let capture = try? JSONDecoder().decode(TerminalZshDraftCapture.self, from: data) else {
            throw Failure.unavailable
        }
        return capture
    }

    static func commit(
        capture: TerminalZshDraftCapture,
        translatedText: String,
        focusObservation: ZshDraftFocusObservation
    ) async throws -> TerminalZshDraftAcknowledgement {
        guard focusObservation.isCurrent else { throw CancellationError() }
        let lease = try ZshDraftCommitLease.create(sessionID: capture.sessionID)
        let invalidationObserver = focusObservation.observeInvalidation { lease.revoke() }
        defer {
            focusObservation.removeInvalidationObserver(invalidationObserver)
            lease.revoke()
        }
        guard focusObservation.isCurrent else { throw CancellationError() }
        let request = TerminalZshDraftCommit(
            ticketID: capture.ticketID,
            sessionID: capture.sessionID,
            hostPID: capture.hostPID,
            shellPID: capture.shellPID,
            startSeconds: capture.startSeconds,
            startMicroseconds: capture.startMicroseconds,
            ttyDevice: capture.ttyDevice,
            processGroup: capture.processGroup,
            buffer: capture.buffer,
            cursor: capture.cursor,
            generation: capture.generation,
            leaseID: lease.id,
            leaseDeadlineUnixMicroseconds: lease.deadlineUnixMicroseconds,
            translatedText: translatedText
        )
        let input = try JSONEncoder().encode(request)
        let data = try await run(
            arguments: ["zsh-draft", "commit"],
            input: input,
            cancellationAction: { lease.revoke() }
        )
        try Task.checkCancellation()
        guard focusObservation.isCurrent else { throw CancellationError() }
        guard let acknowledgement = try? JSONDecoder().decode(
            TerminalZshDraftAcknowledgement.self,
            from: data
        ), acknowledgement.ticketID == capture.ticketID, acknowledgement.committed else {
            throw Failure.unavailable
        }
        return acknowledgement
    }

    private static func run(
        arguments: [String],
        input: Data? = nil,
        cancellationAction: (@Sendable () -> Void)? = nil
    ) async throws -> Data {
        guard let executable = helperURL() else { throw Failure.unavailable }
        let runningProcess = RunningProcess()
        let processTask = Task.detached(priority: .userInitiated) {
            let process = Process()
            let standardOutput = Pipe()
            let standardInput = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = standardOutput
            process.standardError = FileHandle.nullDevice
            process.standardInput = standardInput
            do {
                guard runningProcess.install(process) else { throw CancellationError() }
                defer { runningProcess.clear() }
                try process.run()
                runningProcess.didStart()
                if let input {
                    standardInput.fileHandleForWriting.write(input)
                }
                try? standardInput.fileHandleForWriting.close()
                let output = standardOutput.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw Failure.unavailable }
                return output
            } catch {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                if error is CancellationError { throw error }
                throw Failure.unavailable
            }
        }
        return try await withTaskCancellationHandler {
            let result = try await processTask.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            cancellationAction?()
            runningProcess.cancel()
        }
    }

    private static func helperURL() -> URL? {
        var candidates: [URL] = []
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS/KEYITerminal")
        )
        if let executable = Bundle.main.executableURL {
            candidates.append(executable.deletingLastPathComponent().appendingPathComponent("KEYITerminal"))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
