import AppKit
import KEYICore
import SwiftUI

/// 单例设置窗口；菜单与快捷键入口都汇聚到这里，
/// 深链定位由 AppModel.settingsSection 驱动。
@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)
        window.contentView = NSHostingView(
            rootView: SettingsRootView(model: .shared)
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController 不支持从 nib 初始化")
    }

    func show() {
        window?.title = AppModel.shared.strings.settingsTitle
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsRootView: View {
    @ObservedObject var model: AppModel

    /// 带提供方参数的深链在侧栏中统一显示为“翻译服务”。
    private var sidebarSelection: Binding<AppModel.SettingsSection?> {
        Binding(
            get: {
                if case .providers = model.settingsSection {
                    return .providers(nil)
                }
                return model.settingsSection
            },
            set: { selection in
                guard let selection else { return }
                model.settingsSection = selection
            }
        )
    }

    var body: some View {
        let strings = model.strings

        NavigationSplitView {
            List(selection: sidebarSelection) {
                Label(strings.translationTab, systemImage: "globe")
                    .tag(AppModel.SettingsSection.translation)
                Label(strings.providersTab, systemImage: "network")
                    .tag(AppModel.SettingsSection.providers(nil))
                Label(strings.hotKeyTab, systemImage: "keyboard")
                    .tag(AppModel.SettingsSection.hotKey)
                Label(strings.generalTab, systemImage: "gearshape")
                    .tag(AppModel.SettingsSection.general)
            }
            .listStyle(.sidebar)
            .navigationTitle(strings.appName)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch sidebarSelection.wrappedValue {
            case .translation, .none:
                TranslationPreferencesTab(model: model)
            case .providers:
                ProvidersTab(model: model)
            case .hotKey:
                HotKeyTab(model: model)
            case .general:
                GeneralTab(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 700, minHeight: 480)
    }
}

private struct SettingsPage<Content: View>: View {
    let title: String
    let description: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(28)
        }
    }
}

private struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
    }
}

private struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 116, alignment: .trailing)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

// MARK: - 翻译偏好

struct TranslationPreferencesTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings
        SettingsPage(
            title: strings.translationTab,
            description: strings.translationPreferencesDescription
        ) {
            SettingsGroup {
                SettingsRow(label: strings.targetLanguage) {
                    Picker(
                        strings.targetLanguage,
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
                    .frame(width: 210)
                }

                if model.supportsTranslationCustomization {
                    Divider()
                    SettingsRow(label: strings.scene) {
                        Picker(
                            strings.scene,
                            selection: Binding(
                                get: { model.selectedScene },
                                set: { model.selectScene($0) }
                            )
                        ) {
                            ForEach(TranslationScene.allCases, id: \.self) { scene in
                                Text(strings.sceneName(scene)).tag(scene)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 210)
                    }

                    if model.supportsEnglishStyleCustomization {
                        Divider()
                        SettingsRow(label: strings.style) {
                            Picker(
                                strings.style,
                                selection: Binding(
                                    get: { model.selectedEnglishStyle },
                                    set: { model.selectEnglishStyle($0) }
                                )
                            ) {
                                ForEach(EnglishStyle.allCases, id: \.self) { style in
                                    Text(strings.styleName(style)).tag(style)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 210)
                        }
                    }
                } else {
                    Divider()
                    Label(strings.systemTranslationOptionsInfo, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
            }
        }
    }
}

// MARK: - 翻译服务

struct ProvidersTab: View {
    @ObservedObject var model: AppModel
    @State private var selectedProvider: TranslationProviderID = .deepSeek
    @State private var apiKey = ""
    @State private var endpointText = ""
    @State private var modelText = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    var body: some View {
        let strings = model.strings
        SettingsPage(
            title: strings.providersTab,
            description: strings.translationServicesDescription
        ) {
            SettingsGroup {
                SettingsRow(label: strings.cloudProviderSection) {
                    Picker(strings.cloudProviderSection, selection: cloudSelection) {
                        ForEach(model.apiProviderProfiles) { profile in
                            Text(providerLabel(profile.providerID))
                                .tag(profile.providerID)
                        }
                        Text(providerLabel(.localModel)).tag(TranslationProviderID.localModel)
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Divider()

                switch selectedProvider {
                case .appleSystem:
                    EmptyView()
                case .localModel:
                    localModelForm(strings)
                default:
                    cloudProviderForm(strings)
                }
            }

            if let statusMessage {
                Label(statusMessage, systemImage: statusIsError ? "exclamationmark.circle" : "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(statusIsError ? Color.red : Color.green)
            }
        }
        .onAppear(perform: loadFields)
        .onChange(of: selectedProvider) { _, _ in
            statusMessage = nil
            loadFields()
        }
    }

    /// 云端提供方与本地模型共用一个选择器；appleSystem 不可选。
    private var cloudSelection: Binding<TranslationProviderID> {
        Binding(
            get: { selectedProvider },
            set: { newValue in
                selectedProvider = newValue == .appleSystem ? .deepSeek : newValue
            }
        )
    }

    private func providerLabel(_ provider: TranslationProviderID) -> String {
        let strings = model.strings
        let name = strings.providerName(provider)
        if provider == .localModel {
            return name
        }
        return model.isAPIConfigured(provider)
            ? "\(name) ✓"
            : strings.isEnglish
                ? "\(name) (\(strings.providerNotConfiguredLabel))"
                : "\(name)（\(strings.providerNotConfiguredLabel)）"
    }

    private func loadFields() {
        apiKey = ""
        if selectedProvider == .localModel {
            endpointText = model.localModelEndpoint
            modelText = model.localModelName
        } else {
            endpointText = model.storedEndpoint(for: selectedProvider) ?? ""
            modelText = model.storedModel(for: selectedProvider) ?? ""
        }
    }

    private func cloudProviderForm(_ strings: InterfaceStrings) -> some View {
        Group {
            SettingsRow(label: strings.apiKey) {
                SecureField(
                    strings.apiKey,
                    text: $apiKey,
                    prompt: Text(
                        model.isAPIConfigured(selectedProvider)
                            ? strings.savedLeaveBlank
                            : strings.pasteAPIKey
                    )
                )
                .textFieldStyle(.roundedBorder)
            }
            Divider()
            SettingsRow(label: strings.endpoint) {
                TextField(
                    strings.endpoint,
                    text: $endpointText,
                    prompt: Text("https://example.com/v1/chat/completions")
                )
                .textFieldStyle(.roundedBorder)
            }
            Divider()
            SettingsRow(label: strings.model) {
                TextField(strings.model, text: $modelText)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack(spacing: 10) {
                Spacer()
                if model.selectedProviderID == selectedProvider {
                    Label(strings.currentlyUsed, systemImage: "checkmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(strings.useAsCurrent) {
                    model.selectProvider(selectedProvider)
                }
                .disabled(!model.isAPIConfigured(selectedProvider))
                Button(strings.save) { saveCloudProvider() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }

    private func localModelForm(_ strings: InterfaceStrings) -> some View {
        Group {
            SettingsRow(label: strings.endpoint) {
                TextField(
                    strings.endpoint,
                    text: $endpointText,
                    prompt: Text(strings.localModelEndpointPlaceholder)
                )
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            SettingsRow(label: strings.model) {
                TextField(
                    strings.model,
                    text: $modelText,
                    prompt: Text(strings.localModelPlaceholder)
                )
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            Text(strings.localModelInfo)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            HStack {
                Spacer()
                Button(strings.save) { saveLocalModel() }
                    .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    private func saveCloudProvider() {
        do {
            try model.saveProviderConfiguration(
                providerID: selectedProvider,
                apiKey: apiKey,
                endpoint: endpointText.trimmingCharacters(in: .whitespacesAndNewlines),
                model: modelText
            )
            statusIsError = false
            statusMessage = model.strings.savedHint
            apiKey = ""
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }

    private func saveLocalModel() {
        do {
            try model.saveLocalModelConfiguration(
                endpoint: endpointText.trimmingCharacters(in: .whitespacesAndNewlines),
                model: modelText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            statusIsError = false
            statusMessage = model.strings.savedHint
        } catch {
            statusIsError = true
            statusMessage = error.localizedDescription
        }
    }
}

// MARK: - 快捷键

struct HotKeyTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings
        SettingsPage(
            title: strings.hotKeyTab,
            description: strings.shortcutsDescription
        ) {
            SettingsGroup {
                SettingsRow(label: strings.current) {
                    Text(model.hotKeyConfiguration.displayName)
                        .font(.system(.body, design: .monospaced).weight(.medium))
                }
                Divider()
                HStack(spacing: 10) {
                    Spacer()
                    Button(strings.restoreDefault) {
                        model.restoreDefaultHotKey()
                    }
                    .disabled(model.hotKeyConfiguration == .default)
                    Button(strings.hotKeySettings) {
                        model.configureHotKey()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(16)
            }

            Label(strings.hotKeyRequiresModifier, systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 通用

struct GeneralTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings
        SettingsPage(
            title: strings.generalTab,
            description: strings.generalSettingsDescription
        ) {
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
                    .frame(width: 180)
                }
                Divider()
                SettingsRow(label: strings.accessibilityPermissionSection) {
                    Label(
                        model.hasAccessibilityPermission
                            ? strings.accessibilityGranted
                            : strings.accessibilityNotGranted,
                        systemImage: model.hasAccessibilityPermission
                            ? "checkmark.circle.fill"
                            : "xmark.circle"
                    )
                    .foregroundStyle(
                        model.hasAccessibilityPermission ? Color.green : Color.orange
                    )
                }
                Divider()
                HStack {
                    Spacer()
                    if !model.hasAccessibilityPermission {
                        Button(strings.grantAccessibility) {
                            model.requestAccessibilityPermission()
                        }
                    }
                    Button(strings.openAccessibilitySettings) {
                        model.openAccessibilitySettings()
                    }
                }
                .padding(16)
            }
        }
        .onAppear {
            model.refreshAccessibilityStatus()
        }
    }
}
