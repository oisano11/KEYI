import AppKit

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    init(pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
                item.data(forType: type).map { (type, $0) }
            })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}

/// 借用系统剪贴板的统一出口：进入作用域时快照原内容，退出时若期间
/// 剪贴板没有出现我们之外的新变化就恢复快照，尽量不污染用户剪贴板。
final class ScopedPasteboard {
    private let pasteboard: NSPasteboard
    private let snapshot: PasteboardSnapshot
    private var trackedChangeCount: Int

    init(pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        snapshot = PasteboardSnapshot(pasteboard: pasteboard)
        trackedChangeCount = pasteboard.changeCount
    }

    /// 在每次由当前流程完成的读取或写入之后调用，把基准推进到最新变化。
    func trackLatestChange() {
        trackedChangeCount = pasteboard.changeCount
    }

    var isUnchanged: Bool { pasteboard.changeCount == trackedChangeCount }

    /// 在 defer 中调用：没有新变化才恢复，避免覆盖目标应用已读取的新内容。
    func restoreIfUnchanged() {
        if pasteboard.changeCount == trackedChangeCount {
            snapshot.restore(to: pasteboard)
        }
    }
}
