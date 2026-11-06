import AppKit
import KEYICore
import KEYITranslationClient
import SwiftUI

struct StatusItemLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label {
            Text(model.strings.appName)
        } icon: {
            Image(nsImage: KEYIBirdMark.menuBarImage)
        }
    }
}

/// 菜单栏菜单：顶部名称和服务状态，风格直接列出（后面写引擎），今天确认的汉字与 API 估算费用
/// （与统计页同一份计数），然后是设置和退出。终端恢复、模型迁移、词库更新、下载进度等提示照旧插在最上面。
struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictionary: DictionaryUpdateModel = .shared
    @ObservedObject var stats: StatisticsModel = .shared

    var body: some View {
        let strings = model.strings

        Text(strings.appName)
        Text(statusLine(strings))

        Divider()

        if !model.terminalRecoveryCommands.isEmpty {
            Button(strings.copyOriginalTerminalCommand) {
                model.copyOriginalTerminalCommand()
            }
            Button(strings.discardOriginalTerminalCommand) {
                model.discardOriginalTerminalCommand()
            }
            Divider()
        }

        if model.showsLocalModelMigrationNotice {
            // 只提示一次：点开即看过，之后不再出现。
            Button(strings.localModelMigrationNotice) {
                model.dismissLocalModelMigrationNotice()
                model.openSettings(.providers(.localModel))
            }
            Divider()
        }

        // 词库有新版时提一句，点开就是设置窗口里的词库更新对话框，看过说明再决定装不装。
        if dictionary.pendingOffer != nil {
            Button(strings.dictionaryMenuItem) {
                model.openDictionaryUpdate()
            }
            Divider()
        }

        if let fraction = model.localModelDownloadFraction {
            Button(strings.localModelDownloadingMenu(Int(fraction * 100))) {
                model.openSettings(.providers(.localModel))
            }
            Divider()
        }

        Section(strings.translationStyle) {
            ForEach(KEYITranslationStyle.allCases, id: \.self) { style in
                Toggle(isOn: Binding(
                    get: { model.translationStyle == style },
                    set: { if $0 { model.selectTranslationStyle(style) } }
                )) {
                    Text(strings.isEnglish
                        ? "\(strings.translationStyleName(style)) (\(model.engineLabel(for: style)))"
                        : "\(strings.translationStyleName(style))（\(model.engineLabel(for: style))）")
                }
            }
        }

        Menu(strings.menuValue(strings.targetLanguage, strings.languageName(model.selectedTargetLanguage))) {
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    model.selectTargetLanguage(language)
                } label: {
                    HStack {
                        Text(strings.languageName(language))
                        if language == model.selectedTargetLanguage {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(model.isBusy)

        Divider()

        Text(strings.menuValue(strings.menuTodayHanzi, (stats.days.first?.words.hanzi ?? 0).formatted()))
        Text(strings.menuValue(strings.menuEstimatedCost, costText(stats.days.first?.cost ?? [:])))

        Divider()

        Button(strings.settings) {
            model.openSettings(.translation)
        }
        .keyboardShortcut(",")

        // 草稿桥是旧的桌面专项，和输入法主流程无关，收进「更多」。
        Menu(strings.moreMenu) {
            Button(strings.terminalDraftEditor) {
                model.openTerminalDraftEditor()
            }

            if let guide = Bundle.main.url(forResource: "README", withExtension: "md", subdirectory: "Terminal") {
                Button(strings.terminalDraftGuide) {
                    NSWorkspace.shared.open(guide)
                }
            }
        }

        Divider()

        Button(strings.quitApp) {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
        .onAppear {
            model.refreshAccessibilityStatus()
            stats.reload()
        }
    }

    /// 顶部状态行：翻译服务在跑，本地模型此刻加载到哪一步。
    private func statusLine(_ strings: InterfaceStrings) -> String {
        let local: String
        if model.installedLocalModels.isEmpty {
            local = strings.menuLocalModelMissing
        } else {
            switch model.localModelServerState {
            case .ready: local = strings.menuLocalModelLoaded
            case .starting: local = strings.menuLocalModelLoading
            case .failed: local = strings.menuLocalModelFailed
            case .stopped: local = strings.menuLocalModelIdle
            }
        }
        return "● \(strings.menuServiceRunning) · \(local)"
    }

    private func costText(_ cost: [APIPrice.Currency: Double]) -> String {
        let parts = APIPrice.Currency.allCases.compactMap { currency -> String? in
            guard let amount = cost[currency], amount > 0 else { return nil }
            let digits = amount < 0.01 ? 4 : 2
            return currency.symbol + amount.formatted(.number.precision(.fractionLength(digits)))
        }
        return parts.isEmpty ? "¥0" : parts.joined(separator: " + ")
    }
}
