import AppKit
import KEYICore
import SwiftUI

struct StatusItemLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label(model.strings.appName, systemImage: model.state.symbolName)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings

        Text(model.state.title(using: strings))

        Button(strings.translateCurrentInput) {
            model.triggerFromMenu()
        }
        .disabled(model.isBusy)

        Menu(strings.translationMethod) {
            ForEach(model.providerDescriptors) { provider in
                Button {
                    model.selectProvider(provider.id)
                } label: {
                    HStack {
                        Text(strings.providerName(provider.id))
                        if provider.id == model.selectedProviderID {
                            Spacer()
                            Image(systemName: "checkmark")
                        } else if !provider.isAvailable {
                            Spacer()
                            Text(strings.unavailable)
                        }
                    }
                }
                .disabled(!provider.isAvailable)
            }
        }

        Text(strings.currentProvider(model.selectedProviderID))

        Menu(strings.target(model.selectedTargetLanguage)) {
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

        Menu(strings.scene(model.selectedScene)) {
            ForEach(TranslationScene.allCases) { scene in
                Button {
                    model.selectScene(scene)
                } label: {
                    HStack {
                        Text(strings.sceneName(scene))
                        if scene == model.selectedScene {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(!model.supportsTranslationCustomization)

        Menu(strings.style(model.selectedEnglishStyle)) {
            ForEach(EnglishStyle.allCases) { englishStyle in
                Button {
                    model.selectEnglishStyle(englishStyle)
                } label: {
                    HStack {
                        Text(strings.styleName(englishStyle))
                        if englishStyle == model.selectedEnglishStyle {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(!model.supportsEnglishStyleCustomization)

        let hint = strings.sceneStyleHint(
            supportsScene: model.supportsTranslationCustomization,
            supportsStyle: model.supportsEnglishStyleCustomization,
            scene: model.selectedScene
        )
        if !hint.isEmpty {
            Text(hint)
        }

        Menu(strings.apiManagement) {
            ForEach(model.apiProviderProfiles) { profile in
                Button {
                    model.configureAPI(for: profile.providerID)
                } label: {
                    HStack {
                        Text(strings.providerName(profile.providerID))
                        Spacer()
                        if model.isAPIConfigured(profile.providerID) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Button(strings.configureLocalModel + "…") {
            model.configureLocalModel()
        }

        if model.selectedProviderID == .localModel {
            Text(strings.localModelValue(model.localModelName))
            Text(strings.serviceValue(model.localModelEndpoint))
        }

        if !model.hasAccessibilityPermission {
            Button(strings.grantAccessibility) {
                model.requestAccessibilityPermission()
            }
        }

        Divider()

        Text("\(strings.hotKey)  \(model.hotKeyConfiguration.displayName)")

        Button(strings.hotKeySettings) {
            model.configureHotKey()
        }

        Button(strings.restoreDefault) {
            model.restoreDefaultHotKey()
        }
        .disabled(model.hotKeyConfiguration == .default)

        Button(strings.openAccessibilitySettings) {
            model.openAccessibilitySettings()
        }

        Menu(strings.interfaceLanguage(model.interfaceLanguage)) {
            ForEach(InterfaceLanguage.allCases, id: \.self) { language in
                Button {
                    model.selectInterfaceLanguage(language)
                } label: {
                    HStack {
                        Text(strings.interfaceLanguageName(language))
                        if language == model.interfaceLanguage {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Divider()

        Button(strings.exit) {
            NSApplication.shared.terminate(nil)
        }
        .onAppear {
            model.refreshAccessibilityStatus()
        }
    }
}
