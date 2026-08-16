import AppKit
import KEYICore
import SwiftUI

struct StatusItemLabel: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Label("KEYI 可译", systemImage: model.state.symbolName)
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.state.title)

        Button("翻译当前输入框") {
            model.triggerFromMenu()
        }
        .disabled(model.isBusy)

        Menu("翻译方式") {
            ForEach(model.providerDescriptors) { provider in
                Button {
                    model.selectProvider(provider.id)
                } label: {
                    HStack {
                        Text(provider.name)
                        if provider.id == model.selectedProviderID {
                            Spacer()
                            Image(systemName: "checkmark")
                        } else if !provider.isAvailable {
                            Spacer()
                            Text("待接入")
                        }
                    }
                }
                .disabled(!provider.isAvailable)
            }
        }

        Text("当前：\(model.selectedProviderName)")

        Menu("目标语言：\(model.selectedTargetLanguage.displayName)") {
            ForEach(TranslationLanguage.allCases) { language in
                Button {
                    model.selectTargetLanguage(language)
                } label: {
                    HStack {
                        Text(language.displayName)
                        if language == model.selectedTargetLanguage {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(model.isBusy)

        Menu("翻译场景：\(model.selectedScene.displayName)") {
            ForEach(TranslationScene.allCases) { scene in
                Button {
                    model.selectScene(scene)
                } label: {
                    HStack {
                        Text(scene.displayName)
                        if scene == model.selectedScene {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(!model.supportsTranslationCustomization)

        Menu("英语风格：\(model.selectedEnglishStyle.displayName)") {
            ForEach(EnglishStyle.allCases) { englishStyle in
                Button {
                    model.selectEnglishStyle(englishStyle)
                } label: {
                    HStack {
                        Text(englishStyle.displayName)
                        if englishStyle == model.selectedEnglishStyle {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .disabled(!model.supportsEnglishStyleCustomization)

        if !model.supportsTranslationCustomization {
            Text("翻译场景与英语风格仅适用于模型 API")
        } else if !model.supportsEnglishStyleCustomization {
            if model.selectedScene == .business {
                Text("商务场景优先准确表达，不使用英语风格")
            } else {
                Text("翻译场景适用于全部目标语言；英语风格仅适用于英语")
            }
        }

        Menu("添加/管理模型 API") {
            ForEach(model.apiProviderProfiles) { profile in
                Button {
                    model.configureAPI(for: profile.providerID)
                } label: {
                    HStack {
                        Text(profile.providerID.displayName)
                        Spacer()
                        if model.isAPIConfigured(profile.providerID) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }

        Button("配置本地 Gemma 4…") {
            model.configureLocalModel()
        }

        if model.selectedProviderID == .localModel {
            Text("本地：\(model.localModelName)")
            Text("服务：\(model.localModelEndpoint)")
        }

        if !model.hasAccessibilityPermission {
            Button("授予辅助功能权限") {
                model.requestAccessibilityPermission()
            }
        }

        Divider()

        Text("快捷键  \(model.hotKeyConfiguration.displayName)")

        Button("设置快捷键…") {
            model.configureHotKey()
        }

        Button("恢复默认快捷键") {
            model.restoreDefaultHotKey()
        }
        .disabled(model.hotKeyConfiguration == .default)

        Button("打开辅助功能设置") {
            model.openAccessibilitySettings()
        }

        Divider()

        Button("退出 KEYI 可译") {
            NSApplication.shared.terminate(nil)
        }
        .onAppear {
            model.refreshAccessibilityStatus()
        }
    }
}
