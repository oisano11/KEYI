import InputMethodKit
import KeyiIMETranslation

/// 打拼音时按 . 转出来的一段：照打的样子（`baidu.`）、转出了什么（`百度。`），以及它在暂存段里
/// （能改回去）还是已经上屏（第一个汉字之前的英文 `GitHub.`，留着不动）。
struct KeyiDomainLabel: Equatable {
    var raw: String
    var produced: String
    var held: Bool
}

/// 候选里那一项整段网址。
struct KeyiDomainOffer: Equatable {
    /// 面板上显示的：已上屏的部分照现在的样子，其余照打的样子（`baidu.com`、`GitHub.com`）。
    var shown: String
    /// 放进 Rime 的整段输入（`baidu.com`、`github.com`）。
    var input: String
    /// 选它之后接在暂存段（去掉转出来的字）后面画的：暂存段里那几段照打的样子加后缀（`mail.sina.com`）。
    var marked: String
    /// 排第一（高亮）；整段都能拼成拼音时（`woaini.ai`）排第二，空格照旧出中文。
    var first: Bool
}

/// 不带前缀的网址（用户 2026-11-11「把 baidu.com 这种不带前缀的也修好」）。打拼音时按 . 照旧先按候选
/// 转字（`haode.` → `好的。`，中文句号不能少），同时记下这一段；接着打的字母正好是常见后缀（com、cn、ai…）
/// 时，候选里多一项整段照打的网址。选它（空格、回车、数字、接着打 . / : ? # 或别的标点）就把暂存段末尾
/// 转出来的「百度。」删掉，整段 `baidu.com` 放进 Rime 当网址（recognizer 的 domain 规则），后面的路径照打。
extension InputSession {
    /// 面板顺序里网址那一项的记号（不是 Rime 的候选）。
    static let domainOfferSlot = -1

    /// 这一下按的是不是要记下的「标签.」：正在打只有小写字母的拼音、按 . 、拼音归这个输入框、
    /// 这时没有网址那一项高亮（高亮时按 . 是选它）。返回照打的字母。
    func domainLabelBeingClosed(key: Int, modifiers: UInt, client: any IMKTextInput) -> String? {
        guard key == 0x2e, modifiers & ~UInt(0b11) == 0, !currentPreedit.isEmpty, ownsComposition(client) else { return nil }
        let raw = rimeSession.rawInput
        guard KeyiPunctuationContext.isDomainLabel(raw), !isDomainOffer(at: highlightedIndex) else { return nil }
        return raw
    }

    /// 「标签.」这一下转出了什么：暂存段多出来的（`百度。`），或直接上屏的英文（`GitHub.`，
    /// 小写后正好是打的字母和点）。看不出来、转成了直接上屏的中文（关了自动翻译）就从头再记。
    /// `continuing`：按这一下之前记下的几段还接得上（按完之后暂存段末尾已经是这一段转出的字，不能再拿来核对）。
    func recordDomainLabel(
        raw: String,
        heldBefore: String,
        committed: String,
        continuing: Bool,
        client: any IMKTextInput
    ) {
        let heldAfter = automaticTranslation.heldText
        let label: KeyiDomainLabel
        if committed.isEmpty, heldAfter.count > heldBefore.count, heldAfter.hasPrefix(heldBefore) {
            label = KeyiDomainLabel(raw: raw, produced: String(heldAfter.dropFirst(heldBefore.count)), held: true)
        } else if heldAfter == heldBefore, !committed.isEmpty, committed.lowercased() == raw {
            label = KeyiDomainLabel(raw: raw, produced: committed, held: false)
        } else {
            domainLabels = []
            return
        }
        if !continuing || (domainLabels.last?.held == true && !label.held) {
            domainLabels = []
        }
        domainLabels.append(label)
        domainLabelsClient = client
        domainLabelsAt = ProcessInfo.processInfo.systemUptime
        keepsDomainLabels = true
    }

    /// 记下的几段还接得上：同一个输入框、之后没点过鼠标、暂存段末尾还是它们转出来的字。
    func domainLabelsUsable(for client: (any IMKTextInput)?) -> Bool {
        guard !domainLabels.isEmpty, let client, isSameClient(domainLabelsClient, client) else { return false }
        let now = ProcessInfo.processInfo.systemUptime
        guard secondsSinceMouseDown(now: now) >= now - domainLabelsAt else { return false }
        let held = domainLabels.filter(\.held).map(\.produced).joined()
        return held.isEmpty || automaticTranslation.heldText.hasSuffix(held)
    }

    /// 此刻打的字母能和前面记下的几段接成网址时，候选里多出来的那一项。
    func domainOffer(client: (any IMKTextInput)?) -> KeyiDomainOffer? {
        let suffix = rimeSession.rawInput
        guard KeyiPunctuationContext.bareDomainSuffixes.contains(suffix),
              domainLabelsUsable(for: client)
        else { return nil }
        let shown = domainLabels.map { $0.held ? $0.raw : $0.produced }.joined() + suffix
        let input = domainLabels.map(\.raw).joined() + suffix
        let marked = domainLabels.filter(\.held).map(\.raw).joined() + suffix
        let allPinyin = domainLabels.allSatisfy { KeyiPinyinSyllables.spellsWholly(String($0.raw.dropLast())) }
            && KeyiPinyinSyllables.spellsWholly(suffix)
        return KeyiDomainOffer(shown: shown, input: input, marked: marked, first: !allPinyin)
    }

    /// 网址那一项高亮时，标记文字画成选了它之后的样子（暂存段去掉转出来的字，接上照打的网址），
    /// 看得出来就是网址；挪到别的候选上又画回暂存段加拼音。
    func domainOfferMarkedText(client: any IMKTextInput) -> String? {
        guard !currentPreedit.isEmpty, isDomainOffer(at: highlightedIndex),
              let offer = domainOffer(client: client)
        else { return nil }
        let held = automaticTranslation.heldText
        let produced = domainLabels.filter(\.held).map(\.produced).joined()
        return String(held.dropLast(produced.count)) + offer.marked
    }

    /// 面板上第 `index` 项是不是网址那一项。
    func isDomainOffer(at index: Int) -> Bool {
        guard let order = displayOrder, order.indices.contains(index) else { return false }
        return order[index] == Self.domainOfferSlot
    }

    /// 把网址那一项插进这一页（`adoptCandidates` 排好之后）。
    func placeDomainOffer(rimeCount: Int, client: any IMKTextInput) {
        guard let offer = domainOffer(client: client) else { return }
        var order = displayOrder ?? Array(0..<rimeCount)
        let at = offer.first ? 0 : min(1, currentCandidates.count)
        order.insert(Self.domainOfferSlot, at: at)
        currentCandidates.insert(offer.shown, at: at)
        displayOrder = order
        if offer.first {
            highlightedIndex = 0
        } else if highlightedIndex >= at {
            highlightedIndex += 1
        }
    }

    /// 选网址那一项：暂存段末尾转出来的字删掉，整段照打的样子放进 Rime。`continuing` 是接着打的
    /// . / : ? #，网址留在输入里接着打；没有时整段照打的样子上屏（有暂存段时并进去）。
    func acceptDomainOffer(client: any IMKTextInput, continuing key: Character? = nil) {
        guard let offer = domainOffer(client: client) else { return }
        let held = domainLabels.filter(\.held).map(\.produced).joined()
        if !held.isEmpty { automaticTranslation.dropHeldSuffix(held) }
        let shownPrefix = domainLabels.filter { !$0.held }.map(\.raw).joined()
        domainLabels = []
        let input = offer.input + (key.map(String.init) ?? "")
        addressShownPrefix = shownPrefix
        _ = apply(rimeSession.setInput(input), client: client)
        needsRedraw = true
        if key == nil {
            commitRawInput(client: client, joiningHeldSentence: true)
        }
    }

    /// Rime 输入里已经上屏的开头（`github.`）不再画、不再上屏。退格删进这部分时输入整段作废
    /// （那几个字已经在输入框里，归应用管）。
    func stripAddressShownPrefix(_ text: String) -> String {
        guard !addressShownPrefix.isEmpty, text.hasPrefix(addressShownPrefix) else { return text }
        return String(text.dropFirst(addressShownPrefix.count))
    }
}
