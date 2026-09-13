import AppKit
import Darwin
import Foundation
import OSLog

/// The file must remain in place: unlinking a locked file would allow another
/// process to lock a different inode at the same path.
final class InstanceLock {
    private let descriptor: Int32

    init?(path: String) throws {
        let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}

@MainActor
public enum KEYILauncher {
    public static func run() {
        let logger = Logger(subsystem: "com.keyi.input-translator", category: "Lifecycle")
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            ).appendingPathComponent("com.keyi.input-translator", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard let lock = try InstanceLock(path: directory.appendingPathComponent("instance.lock").path) else {
                logger.info("Duplicate launch ignored; existing instance owns the lock")
                return
            }
            // Also respect older installed builds that predate the shared lock.
            let existing = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.keyi.input-translator"
            ).contains { application in
                guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                      !application.isTerminated else { return false }
                // New builds arbitrate atomically via flock. Counting their
                // short-lived losing launch here could make both launches exit.
                let usesLock = application.bundleURL.flatMap { Bundle(url: $0) }?
                    .object(forInfoDictionaryKey: "KEYISingleInstanceLockVersion") as? Int
                return usesLock != 1
            }
            guard !existing else {
                logger.info("Duplicate launch ignored; another KEYI build is running")
                return
            }
            withExtendedLifetime(lock) { KEYIApp.main() }
        } catch {
            logger.error("Single-instance initialization failed; launch stopped")
            // Do not start an unprotected instance if the lock cannot be created.
            exit(EXIT_FAILURE)
        }
    }
}
