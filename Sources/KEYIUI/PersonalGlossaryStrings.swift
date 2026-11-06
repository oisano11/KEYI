import Foundation

/// 「个人术语表」的文案。
extension InterfaceStrings {
    var glossaryTitle: String { isEnglish ? "Personal glossary" : "个人术语表" }
    var glossaryToggle: String { isEnglish ? "Learn from the AI styles" : "从大模型译法里学习" }
    var glossaryDescription: String {
        isEnglish
            ? "Off by default. When on, sentences the AI styles translate are kept on this Mac until about 20 have built up; the same AI service then picks out fixed renderings (names, products, technical terms) and the sentences are deleted. The local Hy-MT2 styles then translate those terms the same way. Slang and tone are not learned. Nothing is uploaded elsewhere."
            : "默认关闭。打开后，大模型风格翻译过的句子先存在本机，攒够约 20 句由同一个大模型服务挑出固定译法（人名、产品、技术词、固定说法），随即删除这些句子；之后本地 Hy-MT2 风格翻到这些词时照着翻。不学俚语和语气，也不上传到别处。"
    }
    func glossarySummary(terms: Int, pending: Int, enabled: Bool) -> String {
        if isEnglish {
            return enabled ? "\(terms) terms · \(pending) sentences waiting" : "\(terms) terms · not collecting"
        }
        return enabled ? "\(terms) 条术语 · 暂存 \(pending) 句" : "\(terms) 条术语 · 没在收集"
    }
    var glossaryWhyTitle: String {
        isEnglish ? "Why are sentences sent again?" : "为什么要再发一次句子？"
    }
    var glossaryWhyBody: String {
        isEnglish
            ? "KEYI keeps whole sentences, but it cannot tell which Chinese words match which English words: in \"把灰度发布推到仓库 → Push the canary release to the repo\", only understanding the meaning shows that 灰度发布 is \"canary release\". So about every 20 sentences, KEYI sends them once more to the AI service you set up and asks it to pick out the fixed terms. It is the same service that already translated those sentences, and they are deleted right after. The local model is too small to do this reliably. That is also why this is off until you turn it on."
            : "KEYI 存下的是整句，自己分不清哪个中文词对应哪个英文词：比如「把灰度发布推到仓库 → Push the canary release to the repo」，要看懂意思才知道「灰度发布」对应 canary release。所以大约每攒 20 句，KEYI 会把这些句子再发给你自己设置的那个大模型服务一次，请它挑出固定译法。这些句子它翻译时已经看过，整理完马上从本机删除。本地模型太小，做不好这一步。也因为要再发一次，这个功能默认关闭，你打开才开始。"
    }
    var glossaryExtractNow: String { isEnglish ? "Sort out now" : "现在整理" }
    var glossaryShow: String { isEnglish ? "Show…" : "查看…" }
    var glossaryClear: String { isEnglish ? "Clear…" : "清空…" }
    var glossaryRemove: String { isEnglish ? "Remove" : "删除" }
    var glossaryClearTitle: String { isEnglish ? "Clear the personal glossary?" : "清空个人术语表？" }
    var glossaryClearMessage: String {
        isEnglish
            ? "All terms and the sentences waiting to be sorted out are deleted. The switch stays as it is."
            : "所有术语和还没整理的句子都会删除，开关保持不变。"
    }
    func glossaryExtracted(_ count: Int) -> String {
        isEnglish ? "Sorted out: \(count) terms added or updated." : "整理完成：新增或更新 \(count) 条。"
    }
    var glossaryExtractFailed: String {
        isEnglish ? "Could not reach the AI service; the sentences were dropped." : "连不上大模型服务，这批句子没整理成，已丢弃。"
    }
    var glossaryNeedsCloud: String {
        isEnglish ? "Set up an AI service first." : "先配置一个大模型服务。"
    }
    var done: String { isEnglish ? "Done" : "完成" }
}
