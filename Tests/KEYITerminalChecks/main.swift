import Darwin
import Foundation
import KEYICore

private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else { fatalError(message) }
}

@MainActor
private func expectFailure(
    expected: TerminalDraftFile.Error? = nil,
    _ body: () throws -> Void,
    _ message: String
) {
    checkCount += 1
    do {
        try body()
        fatalError(message)
    } catch let error as TerminalDraftFile.Error {
        if let expected, error != expected {
            fatalError("\(message): received an unexpected draft error")
        }
    } catch {
        fatalError("\(message): received a non-draft error")
    }
}

private func makeTemporaryDirectory() throws -> String {
    var template = Array(
        (NSTemporaryDirectory() + "/KEYITerminalChecks.XXXXXX").utf8CString
    )
    guard let path = template.withUnsafeMutableBufferPointer({ buffer -> String? in
        guard let baseAddress = buffer.baseAddress,
              let created = mkdtemp(baseAddress) else {
            return nil
        }
        return String(cString: created)
    }) else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    return path
}

private func path(_ name: String, in directory: String) -> String {
    URL(fileURLWithPath: directory).appendingPathComponent(name).path
}

private func write(_ data: Data, to path: String) throws {
    try data.write(to: URL(fileURLWithPath: path))
}

private func read(_ path: String) throws -> Data {
    try Data(contentsOf: URL(fileURLWithPath: path))
}

private func permissionBits(at path: String) -> mode_t? {
    var information = stat()
    guard path.withCString({ lstat($0, &information) }) == 0 else { return nil }
    return information.st_mode & mode_t(0o7777)
}

let temporaryDirectory = try makeTemporaryDirectory()
defer { try? FileManager.default.removeItem(atPath: temporaryDirectory) }

let draftPath = path("draft.txt", in: temporaryDirectory)
let untouchedPath = path("other.txt", in: temporaryDirectory)
let originalText = "你好🙂\n\tsecond line\r\nlast"
let originalBytes = Data(originalText.utf8)
let untouchedBytes = Data("旁边文件保持不变\n".utf8)
try write(originalBytes, to: draftPath)
try write(untouchedBytes, to: untouchedPath)

let snapshot = try TerminalDraftFile.capture(path: draftPath)
expect(snapshot.text == originalText, "捕获应保留中文、emoji、多行和 tab")
let bytesAfterCapture = try read(draftPath)
expect(bytesAfterCapture == originalBytes, "capture 不得修改草稿文件")

let translatedText = "Hello 🙂\n\tsecond line"
try TerminalDraftFile.commit(translatedText, to: snapshot)
let committedDraftBytes = try read(draftPath)
let committedUntouchedBytes = try read(untouchedPath)
expect(committedDraftBytes == Data(translatedText.utf8), "commit 应只替换目标草稿内容")
expect(committedUntouchedBytes == untouchedBytes, "commit 不得触碰其他文件")

let changedPath = path("externally-changed.txt", in: temporaryDirectory)
try write(Data("original".utf8), to: changedPath)
let changedSnapshot = try TerminalDraftFile.capture(path: changedPath)
let externalText = Data("外部编辑器的新内容".utf8)
try write(externalText, to: changedPath)
expectFailure(expected: .changed, {
    try TerminalDraftFile.commit("translation", to: changedSnapshot)
}, "外部内容变化后必须拒绝提交")
let preservedExternalText = try read(changedPath)
expect(preservedExternalText == externalText, "拒绝冲突时必须保留外部内容")

let replacedPath = path("replaced.txt", in: temporaryDirectory)
let parkedOriginalPath = path("parked-original.txt", in: temporaryDirectory)
let replacementText = Data("replacement stays".utf8)
try write(Data("original identity".utf8), to: replacedPath)
let replacedSnapshot = try TerminalDraftFile.capture(path: replacedPath)
try FileManager.default.moveItem(atPath: replacedPath, toPath: parkedOriginalPath)
try write(replacementText, to: replacedPath)
expectFailure(expected: .changed, {
    try TerminalDraftFile.commit("translation", to: replacedSnapshot)
}, "草稿路径被替换后必须拒绝提交")
let replacementAfterConflict = try read(replacedPath)
let parkedOriginalAfterConflict = try read(parkedOriginalPath)
expect(replacementAfterConflict == replacementText, "拒绝身份冲突时不得覆盖替换文件")
expect(parkedOriginalAfterConflict == Data("original identity".utf8), "路径替换不得修改原文件")

let symlinkTarget = path("symlink-target.txt", in: temporaryDirectory)
let symlinkPath = path("symlink.txt", in: temporaryDirectory)
try write(Data("target".utf8), to: symlinkTarget)
let symlinkResult = symlinkTarget.withCString { target in
    symlinkPath.withCString { symlink(target, $0) }
}
guard symlinkResult == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
expectFailure(expected: .unsafeFile, {
    _ = try TerminalDraftFile.capture(path: symlinkPath)
}, "符号链接草稿必须被拒绝")

let hardlinkPath = path("hardlink.txt", in: temporaryDirectory)
let hardlinkResult = symlinkTarget.withCString { target in
    hardlinkPath.withCString { link(target, $0) }
}
guard hardlinkResult == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
expectFailure(expected: .unsafeFile, {
    _ = try TerminalDraftFile.capture(path: symlinkTarget)
}, "多硬链接文件必须被拒绝")

let invalidUTF8Path = path("invalid-utf8.txt", in: temporaryDirectory)
try write(Data([0xFF, 0xFE]), to: invalidUTF8Path)
expectFailure(expected: .invalidUTF8, {
    _ = try TerminalDraftFile.capture(path: invalidUTF8Path)
}, "无效 UTF-8 草稿必须被拒绝")

for (index, controlByte) in [UInt8(0x00), 0x01, 0x1B, 0x1F].enumerated() {
    let controlPath = path("control-\(index).txt", in: temporaryDirectory)
    try write(Data([0x61, controlByte, 0x62]), to: controlPath)
    expectFailure(expected: .forbiddenControlCharacter, {
        _ = try TerminalDraftFile.capture(path: controlPath)
    }, "NUL、ESC 等 C0 控制字符必须被拒绝")
}

let safeOutputPath = path("safe-output.txt", in: temporaryDirectory)
try write(Data("safe".utf8), to: safeOutputPath)
let safeOutputSnapshot = try TerminalDraftFile.capture(path: safeOutputPath)
expectFailure(expected: .forbiddenControlCharacter, {
    try TerminalDraftFile.commit("unsafe\u{001B}text", to: safeOutputSnapshot)
}, "译文中的 ESC 必须在写回前被拒绝")
let safeOutputAfterRejectedCommit = try read(safeOutputPath)
expect(safeOutputAfterRejectedCommit == Data("safe".utf8), "拒绝控制字符译文时必须保留原草稿")

let oversizedPath = path("oversized.txt", in: temporaryDirectory)
try write(Data("abc".utf8), to: oversizedPath)
expectFailure(expected: .tooLarge, {
    _ = try TerminalDraftFile.capture(path: oversizedPath, maximumBytes: 2)
}, "超出大小上限的草稿必须被拒绝")
try write(Data("x".utf8), to: oversizedPath)
let boundedSnapshot = try TerminalDraftFile.capture(path: oversizedPath, maximumBytes: 2)
expectFailure(expected: .tooLarge, {
    try TerminalDraftFile.commit("你好", to: boundedSnapshot)
}, "超出大小上限的译文必须被拒绝")
let boundedDraftAfterRejectedCommit = try read(oversizedPath)
expect(boundedDraftAfterRejectedCommit == Data("x".utf8), "拒绝超大译文时必须保留原草稿")

let permissionsPath = path("permissions.txt", in: temporaryDirectory)
try write(Data("permission test".utf8), to: permissionsPath)
guard permissionsPath.withCString({ chmod($0, mode_t(0o640)) }) == 0 else {
    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}
let originalPermissions = permissionBits(at: permissionsPath)
let permissionsSnapshot = try TerminalDraftFile.capture(path: permissionsPath)
try TerminalDraftFile.commit("translated", to: permissionsSnapshot)
expect(permissionBits(at: permissionsPath) == originalPermissions, "写回必须保持文件权限")

let emptyPath = path("empty.txt", in: temporaryDirectory)
try write(Data(), to: emptyPath)
let emptySnapshot = try TerminalDraftFile.capture(path: emptyPath)
expect(emptySnapshot.text.isEmpty, "空草稿应允许捕获")
try TerminalDraftFile.commit("", to: emptySnapshot)
let emptyDraftAfterCommit = try read(emptyPath)
expect(emptyDraftAfterCommit.isEmpty, "空译文应允许提交")

let documentCheckCount = try runTerminalEditorDocumentChecks()
checkCount += documentCheckCount
print("KEYITerminalChecks: \(checkCount) checks passed")
