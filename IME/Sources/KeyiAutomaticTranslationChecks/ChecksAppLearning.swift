//
//  ChecksAppLearning.swift
//  按 App 学习候选顺序：只在同一 App、同一拼音下把选过的词排到页前面。
//

import Foundation
import KEYITranslationClient

func checkAppCandidateLearning() {
    section("app candidate learning")
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("keyi-app-learning-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let learning = KEYIAppCandidateLearning(fileURL: file, flushDelay: 60)
    let page = ["是", "时", "事", "市"]

    expect(learning.order(page, app: "com.a", input: "shi") == nil, "learning: nothing learned keeps Rime's order")
    learning.record(app: "com.a", input: "shi", word: "事")
    expectEqual(learning.order(page, app: "com.a", input: "shi"), [2, 0, 1, 3], "learning: app A's pick moves to the front")
    expect(learning.order(page, app: "com.b", input: "shi") == nil, "learning: app B is not affected by app A")
    expect(learning.order(page, app: "com.a", input: "shiji") == nil, "learning: another pinyin is not affected")

    learning.record(app: "com.a", input: "shi", word: "市")
    learning.record(app: "com.a", input: "shi", word: "市")
    expectEqual(learning.order(page, app: "com.a", input: "shi"), [3, 2, 0, 1], "learning: the more-picked word ranks first")

    let old = Date(timeIntervalSinceNow: -200 * 86_400)
    learning.record(app: "com.c", input: "shi", word: "市", date: old)
    learning.record(app: "com.c", input: "shi", word: "市", date: old)
    learning.record(app: "com.c", input: "shi", word: "时")
    expectEqual(learning.order(page, app: "com.c", input: "shi"), [1, 3, 0, 2], "learning: an old habit fades behind a recent pick")

    learning.flush()
    let reloaded = KEYIAppCandidateLearning(fileURL: file, flushDelay: 60)
    expectEqual(reloaded.order(page, app: "com.a", input: "shi"), [3, 2, 0, 1], "learning: picks survive a restart")
    expectEqual(reloaded.summary().apps, 2, "learning: two apps learned")

    for index in 0..<(KEYIAppCandidateLearning.maxEntriesPerApp + 1) {
        reloaded.record(app: "com.cap", input: "x\(index)", word: "词")
    }
    expect(reloaded.summary().entries <= 4 + KEYIAppCandidateLearning.maxEntriesPerApp, "learning: an app keeps at most the cap")
    expectEqual(
        reloaded.order(["次", "词"], app: "com.cap", input: "x\(KEYIAppCandidateLearning.maxEntriesPerApp)"),
        [1, 0],
        "learning: the newest pick survives pruning"
    )
    expect(reloaded.order(["次", "词"], app: "com.cap", input: "x0") == nil, "learning: the oldest pick is pruned first")

    reloaded.reset()
    expectEqual(reloaded.summary().apps, 0, "learning: reset forgets everything")
    expect(!FileManager.default.fileExists(atPath: file.path), "learning: reset deletes the file")
}
