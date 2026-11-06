import Darwin
import Foundation

fileprivate struct TerminalDraftFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let owner: UInt64
    let linkCount: UInt64
    let fileType: UInt64
    let permissions: UInt64
}

fileprivate struct TerminalDraftFileFingerprint: Equatable, Sendable {
    let identity: TerminalDraftFileIdentity
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
    let changeSeconds: Int64
    let changeNanoseconds: Int64
}

/// Reads and conditionally replaces an explicitly supplied editor draft file.
/// It never inspects terminal output or synthesizes terminal input.
/// File locks are advisory; unrelated writers must cooperate with this protocol.
public enum TerminalDraftFile {
    public static let defaultMaximumBytes = 65_536

    public enum Error: Swift.Error, LocalizedError, Equatable {
        case invalidPath
        case invalidLimit
        case unsafeFile
        case tooLarge
        case invalidUTF8
        case forbiddenControlCharacter
        case locked
        case changed
        case ioFailure
        case recoveryFailed

        public var errorDescription: String? {
            switch self {
            case .invalidPath:
                return "草稿文件路径无效。"
            case .invalidLimit:
                return "草稿文件大小上限无效。"
            case .unsafeFile:
                return "草稿必须是当前用户拥有的普通单链接文件。"
            case .tooLarge:
                return "草稿超过允许大小。"
            case .invalidUTF8:
                return "草稿不是有效 UTF-8 文本。"
            case .forbiddenControlCharacter:
                return "草稿包含不允许的控制字符。"
            case .locked:
                return "草稿正被其他协作进程使用。"
            case .changed:
                return "草稿已被更改或替换；未应用译文。"
            case .ioFailure:
                return "草稿文件读写失败。"
            case .recoveryFailed:
                return "草稿写入失败，且无法确认已恢复原文。"
            }
        }
    }

    public struct Snapshot: Sendable {
        public let path: String
        public let text: String

        fileprivate let originalBytes: Data
        fileprivate let fingerprint: TerminalDraftFileFingerprint
        fileprivate let maximumBytes: Int

        fileprivate init(
            path: String,
            text: String,
            originalBytes: Data,
            fingerprint: TerminalDraftFileFingerprint,
            maximumBytes: Int
        ) {
            self.path = path
            self.text = text
            self.originalBytes = originalBytes
            self.fingerprint = fingerprint
            self.maximumBytes = maximumBytes
        }
    }

    public static func capture(
        path: String,
        maximumBytes: Int = defaultMaximumBytes
    ) throws -> Snapshot {
        guard maximumBytes >= 0 else { throw Error.invalidLimit }
        guard isValidPath(path) else { throw Error.invalidPath }

        let descriptor = try openDraft(path: path, writable: false)
        defer { _ = close(descriptor) }
        try acquireLock(descriptor, operation: LOCK_SH)
        defer { _ = flock(descriptor, LOCK_UN) }

        let before = try fingerprint(for: descriptor)
        try validateFile(before, maximumBytes: maximumBytes)
        try requirePath(path, matches: before.identity)

        let bytes = try readBytes(descriptor, maximumBytes: maximumBytes)
        let after = try fingerprint(for: descriptor)
        try validateFile(after, maximumBytes: maximumBytes)
        guard before == after,
              UInt64(bytes.count) == after.size else {
            throw Error.changed
        }
        try requirePath(path, matches: after.identity)

        guard let text = String(data: bytes, encoding: .utf8) else {
            throw Error.invalidUTF8
        }
        try validateText(text, byteCount: bytes.count, maximumBytes: maximumBytes)

        return Snapshot(
            path: path,
            text: text,
            originalBytes: bytes,
            fingerprint: after,
            maximumBytes: maximumBytes
        )
    }

    public static func commit(_ text: String, to snapshot: Snapshot) throws {
        let replacement = try validatedBytes(
            for: text,
            maximumBytes: snapshot.maximumBytes
        )

        let descriptor = try openDraft(path: snapshot.path, writable: true)
        defer { _ = close(descriptor) }
        try acquireLock(descriptor, operation: LOCK_EX)
        defer { _ = flock(descriptor, LOCK_UN) }

        let current = try fingerprint(for: descriptor)
        try validateFile(current, maximumBytes: snapshot.maximumBytes)
        guard current == snapshot.fingerprint else { throw Error.changed }
        try requirePath(snapshot.path, matches: snapshot.fingerprint.identity)

        let currentBytes = try readBytes(
            descriptor,
            maximumBytes: snapshot.maximumBytes
        )
        let afterRead = try fingerprint(for: descriptor)
        guard currentBytes == snapshot.originalBytes,
              afterRead == snapshot.fingerprint else {
            throw Error.changed
        }
        try requirePath(snapshot.path, matches: snapshot.fingerprint.identity)

        do {
            try writeBytes(replacement, to: descriptor)
            try restorePermissionsIfNeeded(
                snapshot.fingerprint.identity.permissions,
                on: descriptor
            )
            try synchronize(descriptor)
        } catch {
            let failure = (error as? Error) ?? Error.ioFailure
            guard restoreOriginal(
                snapshot,
                expectedReplacement: replacement,
                on: descriptor
            ) else {
                throw Error.recoveryFailed
            }
            throw failure
        }

        do {
            let writtenBytes = try readBytes(
                descriptor,
                maximumBytes: snapshot.maximumBytes
            )
            let writtenFingerprint = try fingerprint(for: descriptor)
            guard writtenBytes == replacement,
                  hasSameObject(writtenFingerprint.identity, as: snapshot.fingerprint.identity),
                  writtenFingerprint.identity.permissions == snapshot.fingerprint.identity.permissions else {
                throw Error.changed
            }
            try requirePath(snapshot.path, matches: snapshot.fingerprint.identity)
        } catch {
            let failure = (error as? Error) ?? Error.ioFailure
            if (try? readBytes(
                descriptor,
                maximumBytes: snapshot.maximumBytes
            )) == replacement {
                guard restoreOriginal(
                    snapshot,
                    expectedReplacement: replacement,
                    on: descriptor
                ) else {
                    throw Error.recoveryFailed
                }
            }
            throw failure
        }
    }

    private static func isValidPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.utf8.contains(0) else { return false }
        guard let basename = path.split(separator: "/", omittingEmptySubsequences: false).last,
              !basename.isEmpty,
              basename != ".",
              basename != ".." else {
            return false
        }
        return true
    }

    private static func openDraft(path: String, writable: Bool) throws -> Int32 {
        let access = writable ? O_RDWR : O_RDONLY
        let flags = access | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        let descriptor = path.withCString { open($0, flags) }
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP || code == EMLINK { throw Error.unsafeFile }
            if code == ENOENT || code == ENOTDIR { throw Error.changed }
            throw Error.ioFailure
        }
        return descriptor
    }

    private static func acquireLock(_ descriptor: Int32, operation: Int32) throws {
        guard flock(descriptor, operation | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN { throw Error.locked }
            throw Error.ioFailure
        }
    }

    private static func fingerprint(for descriptor: Int32) throws -> TerminalDraftFileFingerprint {
        var information = stat()
        guard fstat(descriptor, &information) == 0 else { throw Error.ioFailure }
        return makeFingerprint(information)
    }

    private static func fingerprint(at path: String) throws -> TerminalDraftFileFingerprint {
        var information = stat()
        let result = path.withCString { lstat($0, &information) }
        guard result == 0 else { throw Error.changed }
        return makeFingerprint(information)
    }

    private static func makeFingerprint(_ information: stat) -> TerminalDraftFileFingerprint {
        let modification = information.st_mtimespec
        let change = information.st_ctimespec
        let size = information.st_size >= 0
            ? UInt64(information.st_size)
            : UInt64.max
        return TerminalDraftFileFingerprint(
            identity: TerminalDraftFileIdentity(
                device: UInt64(truncatingIfNeeded: information.st_dev),
                inode: UInt64(truncatingIfNeeded: information.st_ino),
                owner: UInt64(information.st_uid),
                linkCount: UInt64(information.st_nlink),
                fileType: UInt64(information.st_mode & S_IFMT),
                permissions: UInt64(information.st_mode & mode_t(0o7777))
            ),
            size: size,
            modificationSeconds: Int64(modification.tv_sec),
            modificationNanoseconds: Int64(modification.tv_nsec),
            changeSeconds: Int64(change.tv_sec),
            changeNanoseconds: Int64(change.tv_nsec)
        )
    }

    private static func validateFile(
        _ fingerprint: TerminalDraftFileFingerprint,
        maximumBytes: Int
    ) throws {
        guard fingerprint.identity.fileType == UInt64(S_IFREG),
              fingerprint.identity.owner == UInt64(getuid()),
              fingerprint.identity.linkCount == 1 else {
            throw Error.unsafeFile
        }
        guard fingerprint.size != UInt64.max,
              fingerprint.size <= UInt64(maximumBytes) else {
            throw Error.tooLarge
        }
    }

    private static func requirePath(
        _ path: String,
        matches identity: TerminalDraftFileIdentity
    ) throws {
        let pathFingerprint = try fingerprint(at: path)
        guard pathFingerprint.identity == identity else { throw Error.changed }
    }

    private static func readBytes(
        _ descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data {
        var result = Data()
        var offset = off_t(0)
        var buffer = [UInt8](repeating: 0, count: 8_192)

        while true {
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                pread(descriptor, rawBuffer.baseAddress, rawBuffer.count, offset)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw Error.ioFailure
            }
            if count == 0 { break }

            let byteCount = Int(count)
            guard result.count <= maximumBytes,
                  byteCount <= maximumBytes - result.count else {
                throw Error.tooLarge
            }
            result.append(contentsOf: buffer.prefix(byteCount))
            offset += off_t(byteCount)
        }
        return result
    }

    private static func validateText(
        _ text: String,
        byteCount: Int,
        maximumBytes: Int
    ) throws {
        guard byteCount <= maximumBytes else { throw Error.tooLarge }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if (value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D)
                || (0x7F...0x9F).contains(value) {
                throw Error.forbiddenControlCharacter
            }
        }
    }

    private static func validatedBytes(
        for text: String,
        maximumBytes: Int
    ) throws -> Data {
        let bytes = Data(text.utf8)
        try validateText(text, byteCount: bytes.count, maximumBytes: maximumBytes)
        return bytes
    }

    private static func writeBytes(_ bytes: Data, to descriptor: Int32) throws {
        try bytes.withUnsafeBytes { rawBuffer in
            var offset = 0
            while offset < rawBuffer.count {
                let count = pwrite(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    rawBuffer.count - offset,
                    off_t(offset)
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw Error.ioFailure
                }
                guard count > 0 else { throw Error.ioFailure }
                offset += Int(count)
            }
        }
        guard ftruncate(descriptor, off_t(bytes.count)) == 0 else {
            throw Error.ioFailure
        }
    }

    private static func restorePermissionsIfNeeded(
        _ permissions: UInt64,
        on descriptor: Int32
    ) throws {
        let current = try fingerprint(for: descriptor)
        guard current.identity.permissions != permissions else { return }
        guard fchmod(descriptor, mode_t(permissions)) == 0 else {
            throw Error.ioFailure
        }
        guard try fingerprint(for: descriptor).identity.permissions == permissions else {
            throw Error.ioFailure
        }
    }

    private static func synchronize(_ descriptor: Int32) throws {
        while fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw Error.ioFailure
        }
    }

    private static func restoreOriginal(
        _ snapshot: Snapshot,
        expectedReplacement: Data,
        on descriptor: Int32
    ) -> Bool {
        guard let before = try? fingerprint(for: descriptor),
              hasSameObject(before.identity, as: snapshot.fingerprint.identity) else {
            return false
        }

        let pathStillNamesFile: Bool
        do {
            try requirePath(snapshot.path, matches: snapshot.fingerprint.identity)
            pathStillNamesFile = true
        } catch {
            pathStillNamesFile = false
        }
        let currentBytes = try? readBytes(
            descriptor,
            maximumBytes: snapshot.maximumBytes
        )
        guard pathStillNamesFile || currentBytes == expectedReplacement else {
            return false
        }

        do {
            try writeBytes(snapshot.originalBytes, to: descriptor)
            try restorePermissionsIfNeeded(
                snapshot.fingerprint.identity.permissions,
                on: descriptor
            )
            try synchronize(descriptor)
            let restored = try readBytes(
                descriptor,
                maximumBytes: snapshot.maximumBytes
            )
            let after = try fingerprint(for: descriptor)
            return restored == snapshot.originalBytes
                && hasSameObject(after.identity, as: snapshot.fingerprint.identity)
                && after.identity.permissions == snapshot.fingerprint.identity.permissions
        } catch {
            return false
        }
    }

    private static func hasSameObject(
        _ lhs: TerminalDraftFileIdentity,
        as rhs: TerminalDraftFileIdentity
    ) -> Bool {
        lhs.device == rhs.device
            && lhs.inode == rhs.inode
            && lhs.owner == rhs.owner
            && lhs.fileType == rhs.fileType
            && lhs.linkCount == rhs.linkCount
    }
}
