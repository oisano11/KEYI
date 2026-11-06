//
//  ChecksDictionaryUpdate.swift
//  雾凇词表更新：词表解析、校验、增删统计、安装 / 退回 / 让位给随包词表。
//

import Foundation
import KEYITranslationClient

private func table(_ name: String, _ lines: [String]) -> String {
    "# Rime dictionary\n---\nname: \(name)\nversion: \"1\"\nsort: by_weight\n...\n" + lines.joined(separator: "\n") + "\n"
}

func checkDictionaryUpdate() {
    section("dictionary update")
    let old = table("base", ["# 注释", "你好\tni hao\t100", "世界\tshi jie\t90", "旧词\tjiu ci\t1"])
    let new = table("base", ["你好\tni hao\t120", "世界\tshi jie\t90", "膈应\tge ying\t5", "黑曜石\thei yao shi\t3"])
    expectEqual(KEYIDictionaryUpdate.entries(in: old)?.count, 3, "dict: comments are not entries")
    expect(KEYIDictionaryUpdate.entries(in: "<html>not found</html>") == nil, "dict: a non-table is rejected")

    let change = KEYIDictionaryUpdate.change(from: old, to: new)
    expectEqual(change.added, 2, "dict: two words added")
    expectEqual(change.removed, 1, "dict: one word removed (a weight change is not a change)")
    expectEqual(change.addedSamples, ["膈应", "黑曜石"], "dict: added samples keep upstream order")
    expectEqual(change.removedSamples, ["旧词"], "dict: removed sample")

    let patch = "@@ -1,3 +1,4 @@\n 世界\tshi jie\t90\n-你好\tni hao\t100\n+你好\tni hao\t120\n-旧词\tjiu ci\t1\n+膈应\tge ying\t5\n+# 「黑耀石」→「黑曜石」\n"
    let fromPatch = KEYIDictionaryUpdate.change(fromPatch: patch, additions: 3, deletions: 2)
    expectEqual(fromPatch.added, 1, "patch: a re-weighted word is not counted as added")
    expectEqual(fromPatch.removed, 1, "patch: removed word")
    expectEqual(fromPatch.addedSamples, ["膈应"], "patch: comment lines are not words")
    expectEqual(KEYIDictionaryUpdate.change(fromPatch: nil, additions: 30, deletions: 10).added, 20, "patch: no patch falls back to line counts")

    expect(KEYIDictionaryUpdate.isAcceptable(new, table: "base", previousCount: 3), "dict: a full table is acceptable")
    expect(!KEYIDictionaryUpdate.isAcceptable(new, table: "ext", previousCount: 3), "dict: a table with another name is rejected")
    expect(!KEYIDictionaryUpdate.isAcceptable(new, table: "base", previousCount: 100), "dict: a truncated table is rejected")

    // 安装 / 退回 / 让位，全在临时目录里。
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("keyi-dict-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let locations = KEYIDictionaryUpdate.Locations(
        rimeUserData: root.appendingPathComponent("Rime", isDirectory: true),
        support: root.appendingPathComponent("DictionaryUpdate", isDirectory: true)
    )
    let rimeData = root.appendingPathComponent("RimeData", isDirectory: true)
    let staged = root.appendingPathComponent("staged", isDirectory: true)
    try? FileManager.default.createDirectory(at: rimeData.appendingPathComponent("rime_ice"), withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    for name in KEYIDictionaryUpdate.tableNames {
        try? table(name, ["词\tci\t1"]).write(to: locations.table(name, in: staged), atomically: true, encoding: .utf8)
    }
    func writeBundled(_ date: String) {
        try? "{\"commit\":\"bundled\",\"date\":\"\(date)\"}".write(
            to: rimeData.appendingPathComponent("rime_ice/KEYI-VERSION.json"), atomically: true, encoding: .utf8)
    }
    writeBundled("2026-10-31T12:00:36Z")
    expectEqual(KEYIDictionaryUpdate.effectiveVersion(rimeData: rimeData, locations)?.commit, "bundled", "dict: nothing installed uses the bundled version")

    let newer = KEYIDictionaryUpdate.Version(commit: "abcdef1234", date: Date(timeIntervalSince1970: 1_800_000_000))
    do { try KEYIDictionaryUpdate.install(from: staged, version: newer, locations) } catch { expect(false, "dict: install threw \(error)") }
    expectEqual(KEYIDictionaryUpdate.installedVersion(locations)?.commit, "abcdef1234", "dict: install records the version")
    expect(FileManager.default.fileExists(atPath: locations.table("tencent").path), "dict: install puts the tables in the user directory")
    expect(!KEYIDictionaryUpdate.yieldToNewerBundle(rimeData: rimeData, locations), "dict: a newer install does not yield to an older bundle")

    do { try KEYIDictionaryUpdate.install(from: staged, version: newer, locations) } catch { expect(false, "dict: reinstall threw \(error)") }
    expect(FileManager.default.fileExists(atPath: locations.table("base", in: locations.previousDirectory).path), "dict: the previous copy is kept")

    writeBundled("2027-12-01T00:00:00Z")
    expect(KEYIDictionaryUpdate.yieldToNewerBundle(rimeData: rimeData, locations), "dict: a newer bundle replaces the user copies")
    expect(KEYIDictionaryUpdate.installedVersion(locations) == nil, "dict: after yielding the bundle is in use")

    do { try KEYIDictionaryUpdate.install(from: staged, version: newer, locations) } catch { expect(false, "dict: install threw \(error)") }
    KEYIDictionaryUpdate.restoreBundled(locations)
    expect(!FileManager.default.fileExists(atPath: locations.table("base").path), "dict: restore removes the user copies")
    expectEqual(KEYIDictionaryUpdate.effectiveVersion(rimeData: rimeData, locations)?.commit, "bundled", "dict: restore goes back to the bundled version")
}
