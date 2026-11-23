import InputMethodKit
import KeyiIMETranslation

/// 英文后面的标点按英文（半角）出（用户 2026-11-08 “When you type in English, any punctuation you
/// add after it should be English punctuation.”）：标点键前面是英文时直接出键上的原字符，不经 Rime
/// 换成中文标点；前面是中文、或什么都看不出来时，照旧交给 Rime 出中文标点。
///
/// 前面的字按这个顺序看：有暂存段（下划线文字）时看暂存段；没有时先看本会话刚写进这个输入框的
/// 文字（`typedTail`），定不了再读输入框光标前的文字。终端一类读不回文字的宿主只靠前两样。
/// 跳过空格、数字和英文标点，碰到的第一个字母或汉字决定（`KeyiPunctuationContext`）。
extension InputSession {
    static let typedTailLimit = 32
    /// 读输入框时最多往回读多少个 UTF-16 单元。
    static let contextReadLimit = 32

    /// 标点键前面是英文时，直接出键上的原字符（有暂存段就并进去，没有就上屏），返回 true。
    /// 返回 nil 时按键照常交给 Rime。正在打拼音时，先按面板上高亮的候选把拼音转成字
    /// （和空格选字一样），再按转出来的字判断。
    func typeEnglishPunctuationIfNeeded(
        _ key: Int,
        modifiers: UInt,
        client: any IMKTextInput
    ) -> Bool? {
        // 只有 Shift / Caps Lock 时才算打字；组合键早已交给应用。
        guard KeyiPunctuationContext.isPunctuationKey(key),
              modifiers & ~UInt(0b11) == 0,
              let scalar = Unicode.Scalar(UInt32(key))
        else { return nil }
        if !currentPreedit.isEmpty, isDomainOffer(at: highlightedIndex), ownsComposition(client) {
            // 不带前缀的网址那一项高亮：. / : ? # 接着打网址，别的标点先把网址上屏再判断。
            if "./:?#".unicodeScalars.contains(scalar) {
                acceptDomainOffer(client: client, continuing: Character(scalar))
                return true
            }
            acceptDomainOffer(client: client)
        }
        if !currentPreedit.isEmpty {
            // 网址、邮箱（www.、https:、xxx@）：标点并进输入交给 Rime，前面的字母不转汉字。
            // ' 是拼音分隔符，= - 是翻页键，留给原来的处理。
            guard ownsComposition(client),
                  !KeyiPunctuationContext.isAddressInput(rimeSession.rawInput + String(Character(scalar))),
                  key != 0x27,
                  key != KeyiRimeKeyMapper.equal,
                  key != KeyiRimeKeyMapper.minus
            else { return nil }
            confirmCompositionAsShown(client: client)
        }
        guard currentPreedit.isEmpty, punctuationFollowsEnglish(client: client) else { return nil }
        let text = String(Character(scalar))
        if !automaticTranslation.takeCommit(text) {
            commitToClient(text, client: client)
        }
        return true
    }

    /// 按面板上高亮的候选把拼音转成字，直到拼音打完；Rime 选不下去时（`nihaov`：选了你好、剩 v）
    /// 按 Rime 显示的样子上屏，已选的中文留着，剩下的字母照打的样子。转出来的字照常并进暂存段或上屏。
    func confirmCompositionAsShown(client: any IMKTextInput) {
        var rounds = 0
        while !currentPreedit.isEmpty, rounds < 16 {
            rounds += 1
            let before = currentPreedit
            if isDomainOffer(at: highlightedIndex) {
                acceptDomainOffer(client: client)
                continue
            }
            let result = currentCandidates.indices.contains(highlightedIndex)
                ? selectVisible(displayIndex: highlightedIndex, client: client)
                : rimeSession.selectHighlightedCandidate()
            guard result.handled else { break }
            _ = apply(result, client: client)
            if currentPreedit == before { break }
        }
        if !currentPreedit.isEmpty {
            let result = rimeSession.commitComposition()
            if result.handled, result.commitText?.isEmpty == false {
                _ = apply(result, client: client)
            }
            if !currentPreedit.isEmpty {
                commitRawInput(client: client, joiningHeldSentence: true)
            }
        }
    }

    /// 此刻打的标点前面是不是英文。
    func punctuationFollowsEnglish(client: any IMKTextInput) -> Bool {
        if automaticTranslation.isHolding {
            // 暂存段从汉字开始，总能定下来。
            return KeyiPunctuationContext.followsEnglish(automaticTranslation.heldText) ?? false
        }
        if let tail = recentlyTyped(in: client),
           let english = KeyiPunctuationContext.followsEnglish(tail)
        {
            return english
        }
        if let before = textBeforeCaret(in: client),
           let english = KeyiPunctuationContext.followsEnglish(before)
        {
            return english
        }
        return false
    }

    // MARK: - 刚写进输入框的文字

    /// 输入法或应用刚往 `client` 里写了 `text`。
    func noteTyped(_ text: String, client: any IMKTextInput) {
        guard !text.isEmpty else { return }
        if typedTailClient == nil || !isSameClient(typedTailClient, client) {
            typedTail = ""
        }
        typedTail = String((typedTail + text).suffix(Self.typedTailLimit))
        typedTailClient = client
        typedTailAt = ProcessInfo.processInfo.systemUptime
    }

    /// 光标可能挪了、文字可能变了（回车、方向键、Tab、组合键、换输入框）：之后前面是什么不知道。
    func forgetTyped() {
        typedTail = ""
        typedTailClient = nil
    }

    /// 输入法没处理、交给应用的键：可见字符由应用照打出来，退格删掉最后一个，其他键之后前文未知。
    func noteKeyLeftToApplication(
        rimeKey: Int?,
        characters: String?,
        chord: Bool,
        client: any IMKTextInput
    ) {
        if !chord, let rimeKey, rimeKey >= 0x20, rimeKey <= 0x7e,
           let characters, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7e })
        {
            noteTyped(characters, client: client)
            return
        }
        if !chord, rimeKey == KeyiRimeKeyMapper.backspace, isSameClient(typedTailClient, client) {
            if !typedTail.isEmpty { typedTail.removeLast() }
            typedTailAt = ProcessInfo.processInfo.systemUptime
            return
        }
        forgetTyped()
    }

    /// 本会话刚写进 `client` 的文字；写完之后点过鼠标（光标可能已经不在这里）就不算。
    private func recentlyTyped(in client: any IMKTextInput) -> String? {
        guard !typedTail.isEmpty, typedTailClient != nil, isSameClient(typedTailClient, client) else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if secondsSinceMouseDown(now: now) < now - typedTailAt {
            forgetTyped()
            return nil
        }
        return typedTail
    }

    /// 输入框光标前的文字（最多 `contextReadLimit` 个单元）；读不到或长度对不上时为 nil。
    private func textBeforeCaret(in client: any IMKTextInput) -> String? {
        let selected = client.selectedRange()
        guard selected.location != NSNotFound, selected.location > 0 else { return nil }
        let span = min(selected.location, Self.contextReadLimit)
        let range = NSRange(location: selected.location - span, length: span)
        guard let text = client.attributedSubstring(from: range)?.string,
              text.utf16count == span
        else { return nil }
        return text
    }
}
