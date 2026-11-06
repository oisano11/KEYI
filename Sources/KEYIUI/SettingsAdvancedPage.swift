import KEYICore
import KEYITranslationClient
import SwiftUI

// 设置「高级」页：目标语言、本地模型档位与下载、大模型服务与 Key、外观（主题与磨砂）、词库更新。

/// 「高级」按关系分三组，一项一行（2026-11-05 用户：「每个功能开关如果有相关关系，可以放到一组里……
/// 要紧凑高效」）：
/// - 翻译：目标语言、本机模型、大模型服务与 Key、个人术语表——都是「译文怎么来」。
/// - 外观：主题；一个磨砂滑块（2026-11-05 由透明度、模糊度合成）。
/// - 通用：界面语言、桌面快捷键、辅助功能、拼音词库——设一次就不动的。
/// 每行只留名称、一句短注和控件，长说明放进悬停提示。
struct AdvancedPage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictionary: DictionaryUpdateModel = .shared
    @ObservedObject var stats: StatisticsModel = .shared

    var body: some View {
        let strings = model.strings
        DetailPage(title: strings.advancedSettings, spacing: 10) {
            SettingsSectionTitle(strings.translationSection)
            SettingsGroup {
                SettingsRow(label: strings.targetLanguage, help: strings.targetLanguageDetail) {
                    Picker(
                        strings.languageLabel,
                        selection: Binding(
                            get: { model.selectedTargetLanguage },
                            set: { model.selectTargetLanguage($0) }
                        )
                    ) {
                        ForEach(TranslationLanguage.allCases, id: \.self) { language in
                            Text(strings.languageName(language)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(
                    label: strings.localModelShortLabel,
                    note: "Hy-MT2",
                    noteColor: KEYIPalette.accentText,
                    help: strings.localModelRowDetail
                ) {
                    if model.installedLocalModels.isEmpty, model.localModelDownloadProgress.isEmpty {
                        Button(strings.downloadLocalModelButton) { model.downloadAndUseLocalModel(.standard) }
                    } else {
                        LocalModelControl(model: model)
                    }
                }
                SettingsDivider()
                CloudServiceInline(model: model)
                SettingsDivider()
                PersonalGlossaryRow(model: model)
            }

            SettingsSectionTitle(strings.appearanceSection)
            SettingsGroup {
                SettingsRow(label: strings.themeLabel, help: strings.themeDetail) {
                    ThemePicker(model: model)
                }
                SettingsDivider()
                SettingsRow(label: strings.glassLabel, help: strings.glassHelp) {
                    FrostSlider(
                        value: model.glassFrost,
                        clearLabel: strings.glassFrostClear,
                        thickLabel: strings.glassFrostThick
                    ) {
                        model.setGlassFrost($0, commit: false)
                    } onCommit: {
                        model.setGlassFrost(model.glassFrost, commit: true)
                    }
                }
            }

            SettingsSectionTitle(strings.generalSection)
            SettingsGroup {
                SettingsRow(label: strings.interfaceLanguage) {
                    Picker(
                        strings.interfaceLanguage,
                        selection: Binding(
                            get: { model.interfaceLanguage },
                            set: { model.selectInterfaceLanguage($0) }
                        )
                    ) {
                        ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                            Text(strings.interfaceLanguageName(language)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsDivider()
                SettingsRow(label: strings.desktopHotKey, note: strings.desktopHotKeyNote, help: strings.shortcutsDescription) {
                    HStack(spacing: 8) {
                        Text(model.hotKeyConfiguration.displayName)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(KEYIPalette.accentText)
                            .padding(.trailing, 4)
                        // 已是默认时不显示「恢复默认」：禁用的按钮在暗色下几乎看不见。
                        if model.hotKeyConfiguration != .default {
                            Button(strings.restoreDefault) { model.restoreDefaultHotKey() }
                        }
                        Button(strings.hotKeySettings) { model.configureHotKey() }
                    }
                }
                SettingsDivider()
                SettingsRow(label: strings.accessibilityShort) {
                    HStack(spacing: 8) {
                        if model.hasAccessibilityPermission {
                            // 状态用系统绿，不用主题强调色：朱砂主题下红色对勾像出错。
                            Label {
                                Text(strings.accessibilityGranted).foregroundStyle(KEYIPalette.ink2)
                            } icon: {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(nsColor: .systemGreen))
                            }
                            .font(.system(size: 12))
                        } else {
                            Label(strings.accessibilityNotGranted, systemImage: "xmark.circle")
                                .foregroundStyle(KEYIPalette.api)
                            Button(strings.openAccessibilitySettings) { model.openAccessibilitySettings() }
                            Button(strings.grantAccessibility) { model.requestAccessibilityPermission() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                }
                SettingsDivider()
                SettingsRow(
                    label: strings.dictionarySection,
                    note: strings.dictionaryVersionShort(dictionary.current, installed: dictionary.isInstalledUpdate),
                    detail: dictionaryShowsStatus ? dictionaryStatusText(dictionary, strings: strings) : nil,
                    help: dictionaryStatusText(dictionary, strings: strings)
                        + (strings.isEnglish ? " " : "") + strings.dictionaryRowDetail
                ) {
                    HStack(spacing: 8) {
                        if dictionary.isBusy { ProgressView().controlSize(.small) }
                        if dictionary.pendingOffer != nil {
                            Button(strings.dictionaryReview) { model.showsDictionaryUpdateSheet = true }
                                .buttonStyle(.borderedProminent)
                        }
                        Button(strings.dictionaryCheck) { dictionary.check(userInitiated: true) }
                        if dictionary.isInstalledUpdate {
                            Button(strings.dictionaryRestore) { dictionary.restoreBundled() }
                        }
                    }
                    .disabled(dictionary.isBusy || !stats.inputMethodInstalled)
                }
            }
        }
        .controlSize(.small)
        .onAppear {
            model.refreshAccessibilityStatus()
            dictionary.refreshCurrent()
        }
    }

    /// 平时「上次检查」只在悬停提示里；正在检查、下载、装好或出错时才在行里多写一行。
    private var dictionaryShowsStatus: Bool {
        switch dictionary.phase {
        case .idle, .available: false
        default: true
        }
    }
}

/// 三套主题：每个按钮一个色点（该主题此刻外观下的强调色）加名字，选中的主题色描边、浅底、主题色字。
private struct ThemePicker: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 6) {
            ForEach(KEYITheme.allCases, id: \.self) { theme in
                let selected = model.appearanceTheme == theme
                let color = Color(nsColor: theme.tokens(dark: colorScheme == .dark).accent.nsColor)
                Button {
                    model.selectAppearanceTheme(theme)
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(color)
                            .frame(width: 9, height: 9)
                        // 每个主题的名字用它自己的颜色写，选之前就看得出是什么色。
                        Text(model.strings.themeName(theme))
                            .font(.system(size: 12, weight: selected ? .semibold : .medium))
                            .foregroundStyle(color)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(selected ? KEYIPalette.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(selected ? KEYIPalette.accent : KEYIPalette.line2, lineWidth: selected ? 1.5 : 1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// 磨砂一个滑块：左端「通透」、右端「厚实」，像苹果的材质从薄到厚（2026-11-05 由透明度、模糊度两个合成）。
/// 拖动时只改界面（设置窗口的玻璃当场跟着变），松手才保存并通知输入法。
private struct FrostSlider: View {
    let value: Double
    let clearLabel: String
    let thickLabel: String
    let onChange: (Double) -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(clearLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(KEYIPalette.ink2)
                .fixedSize()
            Slider(
                value: Binding(get: { value }, set: { onChange($0) }),
                in: KEYIAppearanceSettings.glassFrostRange,
                onEditingChanged: { editing in
                    if !editing { onCommit() }
                }
            )
            .frame(width: 150)
            Text(thickLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(KEYIPalette.ink2)
                .fixedSize()
            FrostPreview(frost: value)
        }
        .fixedSize()
    }
}

/// 磨砂滑块旁的小预览：彩色条纹上放一个迷你候选胶囊，和光标旁面板同一套映射
/// （`KEYIAppearanceSettings.panelGlass`）。拖滑块时光标面板不在屏幕上，靠它当场看出面板会变成什么样。
/// 只是展示，不能点。
private struct FrostPreview: View {
    let frost: Double
    @Environment(\.colorScheme) private var colorScheme

    /// 候选行用面板的量宽代码（`KEYICandidateRow`），按真实尺寸排：三个候选的胶囊和面板上一样大。
    private static let row = KEYICandidateRow.layout(texts: ["你", "呢", "泥"], maxWidth: 400)
    private static let capsule = row.size
    static let size = CGSize(width: capsule.width + 16, height: capsule.height + 14)
    /// 条纹宽一些：太细的条纹在最通透（模糊 3）时也会糊掉，看不出「通透」。
    private static let stripeWidth: CGFloat = 13
    private static let stripes: [Color] = [
        .black, .white, Color(red: 0.92, green: 0.26, blue: 0.21), .white,
        Color(red: 0.13, green: 0.47, blue: 0.95), .white, Color(red: 1.0, green: 0.76, blue: 0.03),
    ]

    var body: some View {
        let dark = colorScheme == .dark
        let glass = KEYIAppearanceSettings.panelGlass(frost: frost, dark: dark)
        let tokens = KEYIPalette.theme.tokens(dark: dark)
        let shape = Capsule(style: .continuous)
        ZStack {
            Self.stripeField
            // 胶囊里是同一片条纹模糊后再叠玻璃底色，和面板的「背后模糊 + 主题玻璃色」一致。
            ZStack {
                Self.stripeField.blur(radius: glass.blurRadius, opaque: true)
                Color(nsColor: tokens.glassBase.nsColor).opacity(glass.tintAlpha)
            }
            .frame(width: Self.size.width, height: Self.size.height)
            .mask(shape.frame(width: Self.capsule.width, height: Self.capsule.height))
            shape
                .strokeBorder(Color(nsColor: tokens.line.nsColor), lineWidth: 1)
                .frame(width: Self.capsule.width, height: Self.capsule.height)
            CandidateRowView(layout: Self.row, tokens: tokens)
                .frame(width: Self.capsule.width, height: Self.capsule.height)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityHidden(true)
    }

    private static var stripeField: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            var index = 0
            while x < size.width {
                context.fill(
                    Path(CGRect(x: x, y: 0, width: stripeWidth, height: size.height)),
                    with: .color(stripes[index % stripes.count])
                )
                x += stripeWidth
                index += 1
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// 把 `KEYICandidateRow` 画出来：和输入法面板的 `KeyiCandidateContentView` 同一份绘制代码。
private struct CandidateRowView: NSViewRepresentable {
    let layout: KEYICandidateRow.Layout
    let tokens: KEYIThemeTokens

    func makeNSView(context: Context) -> RowView { RowView() }

    func updateNSView(_ view: RowView, context: Context) {
        view.layout = layout
        view.tokens = tokens
        view.needsDisplay = true
    }

    final class RowView: NSView {
        var layout = KEYICandidateRow.Layout.empty
        var tokens: KEYIThemeTokens?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let tokens else { return }
            KEYICandidateRow.draw(layout, highlightedIndex: 0, tokens: tokens)
        }
    }
}

// MARK: - 本地模型档位

/// 本机模型一行右边：轻量、标准两档按钮，在用的那档描边并写「正在使用」；没下载的档位点了就下载并在下完后使用。
/// 删除和模型许可收在「更多」菜单里。正在下载时换成进度条和取消。
private struct LocalModelControl: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings
        if let (tier, bytes) = downloading {
            let total = LocalTranslationModelCatalog.model(for: tier).byteCount
            HStack(spacing: 8) {
                ProgressView(value: Double(bytes), total: Double(total))
                    .tint(KEYIPalette.local)
                    .frame(width: 110)
                Text(strings.localModelDownloading(byteText(bytes), byteText(total)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(strings.cancel) { model.cancelLocalModelDownload(tier) }
                    .controlSize(.small)
            }
        } else if !model.installedLocalModels.isEmpty {
            HStack(spacing: 10) {
                // 两档并排，在用的那档强调色描边、浅底，并写明「正在使用」；没下载的写「下载…」，点了就下载。
                HStack(spacing: 6) {
                    ForEach(LocalTranslationModelCatalog.models, id: \.tier) { localModel in
                        tierButton(localModel, strings: strings)
                    }
                }
                Menu(strings.moreMenu) {
                    ForEach(LocalTranslationModelCatalog.models.filter { model.installedLocalModels.contains($0.tier) }, id: \.tier) { localModel in
                        Button(role: .destructive) {
                            model.deleteLocalModel(localModel.tier)
                        } label: {
                            Text(strings.deleteLocalModelTier(
                                strings.localModelTierShort(localModel.tier),
                                byteText(localModel.byteCount)
                            ))
                        }
                    }
                    Divider()
                    Link(strings.localModelLicense, destination: LocalTranslationModelCatalog.licenseURL)
                }
                .fixedSize()
            }
        }
        if let error = model.localModelDownloadErrors.values.first, downloading == nil, !model.installedLocalModels.isEmpty {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var downloading: (LocalTranslationModelTier, Int64)? {
        model.localModelDownloadProgress.first.map { ($0.key, $0.value) }
    }

    private func tierButton(_ localModel: LocalTranslationModel, strings: InterfaceStrings) -> some View {
        let tier = localModel.tier
        let selected = model.installedLocalModelInUse?.tier == tier
        return Button {
            guard !selected else { return }
            if model.installedLocalModels.contains(tier) {
                model.useLocalModel(tier)
            } else {
                model.downloadAndUseLocalModel(tier)
            }
        } label: {
            HStack(spacing: 6) {
                Text(tierLabel(localModel, strings: strings))
                    .font(.system(size: 12, weight: selected ? .semibold : .regular))
                if selected {
                    Text(strings.localModelInUse)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(KEYIPalette.onAccent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(KEYIPalette.accent, in: Capsule())
                }
            }
            .foregroundStyle(selected ? KEYIPalette.accentText : KEYIPalette.ink)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(selected ? KEYIPalette.accentTint : Color.clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(selected ? KEYIPalette.accent : KEYIPalette.line2, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(strings.localModelTierSummary(tier))（\(byteText(localModel.byteCount))）")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// 已下载的写档位名；没下载的加「下载」二字，点了就下载。
    private func tierLabel(_ localModel: LocalTranslationModel, strings: InterfaceStrings) -> String {
        let name = strings.localModelTierName(localModel.tier)
        return model.installedLocalModels.contains(localModel.tier)
            ? name
            : strings.downloadTierLabel(name)
    }

    private func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 大模型服务

/// 大模型框头右边：选服务、填 Key。普通服务只要 Key；自定义服务在下面多出 Endpoint 和模型。
/// 选中的已配置服务就是三种大模型风格在用的。
private struct CloudServiceInline: View {
    @ObservedObject var model: AppModel
    @State private var apiKey = ""
    @State private var replacingAPIKey = false
    @State private var endpointText = ""
    @State private var modelText = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var provider: TranslationProviderID { model.cloudProviderShownInSettings }

    var body: some View {
        let strings = model.strings
        let configured = model.isAPIConfigured(provider)
        let editing = !configured || replacingAPIKey
        // 「服务」「API Key」各占一行，控件和左边标题对齐；自定义服务再多 Endpoint、模型两行。
        VStack(alignment: .leading, spacing: 0) {
            SettingsRow(label: strings.cloudServiceShortLabel, note: strings.cloudServiceNote, help: strings.cloudServiceDetail) {
                Picker(strings.translationMethod, selection: providerSelection) {
                    ForEach(model.providerDescriptors.filter { $0.isAvailable && $0.id.requiresAPIConfiguration }) { descriptor in
                        Text(providerLabel(descriptor.id)).tag(descriptor.id)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            SettingsDivider()
            SettingsRow(
                label: strings.apiKey,
                detail: statusMessage,
                detailColor: statusIsError ? KEYIPalette.danger : KEYIPalette.ink2
            ) {
                HStack(spacing: 8) {
                    if editing {
                        SecureField(strings.apiKey, text: $apiKey, prompt: Text(strings.pasteAPIKey))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 200)
                            .onSubmit(save)
                        if replacingAPIKey {
                            Button(strings.cancel) {
                                apiKey = ""
                                replacingAPIKey = false
                            }
                        }
                        Button(strings.save, action: save)
                            .buttonStyle(.borderedProminent)
                            .tint(KEYIPalette.cloud)
                            .disabled(apiKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                        Label(strings.savedAPIKeyMasked, systemImage: "key.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(KEYIPalette.ink2)
                        Button(strings.replaceAPIKey) { replacingAPIKey = true }
                    }
                }
            }
            if provider == .relay {
                SettingsDivider()
                SettingsRow(label: strings.endpoint) {
                    TextField(
                        strings.endpoint,
                        text: $endpointText,
                        prompt: Text("https://example.com/v1/chat/completions")
                    )
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .frame(width: 300)
                }
                SettingsDivider()
                SettingsRow(label: strings.model) {
                    HStack(spacing: 8) {
                        TextField(strings.model, text: $modelText, prompt: Text(strings.model))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(width: editing ? 300 : 230)
                        if !editing {
                            Button(strings.save, action: save)
                        }
                    }
                }
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: provider) { _, _ in
            statusMessage = nil
            loadFields()
        }
    }

    /// 选中已配置好的服务立刻用于大模型风格；没配置的只换表单。
    private var providerSelection: Binding<TranslationProviderID> {
        Binding(
            get: { provider },
            set: { model.chooseProviderInSettings($0) }
        )
    }

    private func providerLabel(_ id: TranslationProviderID) -> String {
        let strings = model.strings
        let name = strings.providerName(id)
        guard !model.isAPIConfigured(id) else { return name }
        let missing = strings.providerNotConfiguredLabel
        return strings.isEnglish ? "\(name) (\(missing))" : "\(name)（\(missing)）"
    }

    private func loadFields() {
        apiKey = ""
        replacingAPIKey = false
        endpointText = model.storedEndpoint(for: provider) ?? ""
        modelText = model.storedModel(for: provider) ?? ""
    }

    private func save() {
        do {
            try model.saveProviderConfiguration(
                providerID: provider,
                apiKey: apiKey,
                endpoint: endpointText.trimmingCharacters(in: .whitespacesAndNewlines),
                model: modelText
            )
            model.selectProvider(provider)
            statusIsError = false
            statusMessage = model.strings.savedHint
            apiKey = ""
            replacingAPIKey = false
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}
