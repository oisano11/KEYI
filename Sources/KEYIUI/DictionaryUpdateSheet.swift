import KEYITranslationClient
import SwiftUI

/// 词库更新对话框：先说明这次更新了什么，再由用户点「更新」或「暂不」。
/// 菜单栏的新词库提示和「高级 › 拼音词库」的「查看新版…」都打开它。
struct DictionaryUpdateSheet: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictionary: DictionaryUpdateModel = .shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let strings = model.strings
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "book.closed")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(KEYIPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(KEYIPalette.accentTint, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(strings.dictionarySheetTitle)
                        .font(.system(size: 14, weight: .semibold))
                    Text(subtitle(strings))
                        .font(.system(size: 12))
                        .foregroundStyle(KEYIPalette.ink2)
                }
            }

            if let offer = dictionary.pendingOffer {
                HStack(spacing: 8) {
                    countTile(strings.dictionaryAddedLabel, "+\(offer.change.added.formatted())", accent: true)
                    countTile(strings.dictionaryRemovedLabel, "−\(offer.change.removed.formatted())", accent: false)
                }
                samples(strings.dictionaryAddedSamples, offer.change.addedSamples)
                samples(strings.dictionaryRemovedSamples, offer.change.removedSamples)
                if !offer.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(strings.dictionaryNotes)
                        ForEach(offer.notes, id: \.self) { note in
                            Text("· \(note)")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(KEYIPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Text(strings.dictionaryOfferNote)
                    .font(.system(size: 12))
                    .foregroundStyle(KEYIPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 装完、退回或查不到新版时，对话框只报告结果。
                Text(dictionaryStatusText(dictionary, strings: strings))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if dictionary.isBusy { ProgressView().controlSize(.small) }
                Spacer()
                if dictionary.pendingOffer != nil {
                    Button(strings.dictionaryNotNow) {
                        dictionary.dismiss()
                        dismiss()
                    }
                    Button(strings.dictionaryUpdate) { dictionary.install() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(dictionary.isBusy)
                } else {
                    Button(strings.done) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(dictionary.isBusy)
                }
            }
        }
        .foregroundStyle(KEYIPalette.ink)
        .tint(KEYIPalette.accent)
        .padding(20)
        .frame(width: 380)
        .background(KEYIPalette.surface)
        .animation(.easeOut(duration: 0.15), value: dictionary.phase)
    }

    private func subtitle(_ strings: InterfaceStrings) -> String {
        if let offer = dictionary.pendingOffer {
            return strings.dictionarySheetVersions(offer.to, dictionary.current ?? offer.from)
        }
        return strings.dictionaryVersion(dictionary.current, installed: dictionary.isInstalledUpdate)
    }

    private func countTile(_ label: String, _ value: String, accent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(KEYIPalette.ink2)
            Text(value)
                .font(.system(size: 18, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(accent ? KEYIPalette.accent : KEYIPalette.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(KEYIPalette.surface2, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    @ViewBuilder
    private func samples(_ title: String, _ words: [String]) -> some View {
        if !words.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KEYIPalette.ink3)
                FlowRow(spacing: 6) {
                    ForEach(words, id: \.self) { word in
                        Text(word)
                            .font(.system(size: 12))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(KEYIPalette.surface2, in: Capsule())
                    }
                }
            }
        }
    }
}

/// 词库此刻的状态一句话：上次检查、正在下载、装好了、失败原因等。
@MainActor
func dictionaryStatusText(_ dictionary: DictionaryUpdateModel, strings: InterfaceStrings) -> String {
    switch dictionary.phase {
    case .idle, .available: strings.dictionaryLastCheck(dictionary.lastCheck)
    case .checking: strings.dictionaryChecking
    case .upToDate: strings.dictionaryUpToDate
    case let .downloading(index, total): strings.dictionaryDownloading(index, total)
    case .verifying: strings.dictionaryVerifying
    case .applying: strings.dictionaryApplying
    case let .installed(change, applied): strings.dictionaryInstalled(change, applied: applied)
    case let .restored(applied): strings.dictionaryRestored(applied: applied)
    case let .failed(message): message
    }
}

/// 自动换行的一排小标签（示例词、术语）。
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (subview, point) in zip(subviews, result.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var points: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), points)
    }
}
