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

        Button(strings.settings) {
            model.openSettings(.translation)
        }
        .keyboardShortcut(",")

        Divider()

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

        Menu(strings.targetLanguage) {
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

        if model.supportsTranslationCustomization {
            Menu(strings.scene) {
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

            if model.supportsEnglishStyleCustomization {
                Menu(strings.style) {
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
