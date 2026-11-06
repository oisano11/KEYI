import KEYICore
import KEYITranslationClient
import SwiftUI

// 设置首页「翻译风格」：本机与大模型两组风格卡片及各组引擎状态。

/// 「想要什么样的英文？」：风格分「本机翻译」「大模型 API」两组，组名旁写引擎和隐私说明，
/// 每张卡片是同一句中文的示例译文，点卡片即选用。引擎没就绪时组名下一行直说缺什么、暂时怎么翻。
/// 目标语言、本地模型档位和大模型服务都在「高级」里，页底一条提示带过去。
struct TranslationPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let strings = model.strings
        DetailPage(title: strings.styleQuestion, spacing: 12) {
            HStack(spacing: 8) {
                Text(strings.styleIntro)
                    .font(.system(size: 12.5))
                    .foregroundStyle(KEYIPalette.ink2)
                HStack(spacing: 6) {
                    Text(strings.sampleSourceLabel)
                        .font(.system(size: 11))
                        .opacity(0.85)
                    Text(strings.styleExampleSource)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .foregroundStyle(KEYIPalette.onAccent)
                .padding(.horizontal, 9)
                .padding(.vertical, 2)
                .background(KEYIPalette.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .padding(.top, -4)

            StyleSection(
                title: strings.localStylesGroup,
                detail: strings.localGroupDetail(model.engineLabel(for: .natural)),
                tint: KEYIPalette.local,
                status: localStatus(strings),
                styles: KEYITranslationStyle.allCases.filter { !$0.usesCloud },
                model: model
            ) {
                if model.installedLocalModels.isEmpty, model.localModelDownloadProgress.isEmpty {
                    Button(strings.downloadLocalModelButton) { model.downloadAndUseLocalModel(.standard) }
                        .controlSize(.small)
                }
            }

            StyleSection(
                title: strings.cloudStylesGroup,
                detail: strings.cloudGroupDetail(
                    model.cloudProviderInUse.map(strings.engineName) ?? strings.engineNeedsAPIKey
                ),
                tint: KEYIPalette.cloud,
                status: cloudStatus(strings),
                styles: KEYITranslationStyle.allCases.filter(\.usesCloud),
                model: model
            ) {
                if model.cloudProviderInUse == nil {
                    Button(strings.addAPIKey) { model.openSettings(.providers(nil)) }
                        .controlSize(.small)
                }
            }

            HStack(spacing: 12) {
                Image(systemName: "info.circle")
                    .foregroundStyle(KEYIPalette.ink2)
                Text(strings.targetLanguageFooter(strings.languageName(model.selectedTargetLanguage)))
                    .font(.system(size: 12))
                    .foregroundStyle(KEYIPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(strings.changeInAdvanced) {
                    withAnimation(.snappy(duration: 0.2)) { model.settingsSection = .general }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(KEYIPalette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(KEYIPalette.chip, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    /// 本机组的状态：就绪时不写（组名旁已写「文字不出本机」）；没就绪时说缺什么、暂用什么。
    private func localStatus(_ strings: InterfaceStrings) -> EngineStatus? {
        if model.installedLocalModels.isEmpty {
            return .missing(strings.localEngineMissing)
        }
        if model.selectedProviderID == .localModel {
            switch model.localModelServerState {
            case .starting: return .busy(strings.localModelLoading)
            case let .failed(error): return .failed(error.localizedDescription)
            case .stopped, .ready: break
            }
        }
        return nil
    }

    private func cloudStatus(_ strings: InterfaceStrings) -> EngineStatus? {
        model.cloudProviderInUse == nil ? .missing(strings.cloudEngineMissing) : nil
    }
}

/// 引擎没就绪时组名下的状态：加载中、缺配置（说明暂用的办法）、出错。
enum EngineStatus {
    case ready(String)
    case busy(String)
    case missing(String)
    case failed(String)

    var text: String {
        switch self {
        case let .ready(text), let .busy(text), let .missing(text), let .failed(text): text
        }
    }

    var color: Color {
        switch self {
        case .ready, .busy: KEYIPalette.ink2
        case .missing: KEYIPalette.api
        case .failed: KEYIPalette.danger
        }
    }

    var symbol: String {
        switch self {
        case .ready: "checkmark.circle.fill"
        case .busy: "circle.dotted"
        case .missing: "exclamationmark.triangle.fill"
        case .failed: "xmark.octagon.fill"
        }
    }
}

/// 一组风格：组名、引擎与隐私说明（组色），需要时一行状态，下面三张风格卡片。
private struct StyleSection<Accessory: View>: View {
    let title: String
    let detail: String
    let tint: Color
    let status: EngineStatus?
    let styles: [KEYITranslationStyle]
    @ObservedObject var model: AppModel
    @ViewBuilder let accessory: Accessory

    var body: some View {
        let strings = model.strings
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                KEYIMixedText.text(title, size: 12, weight: .semibold)
                    .foregroundStyle(KEYIPalette.accentText)
                KEYIMixedText.text(detail, size: 11.5, weight: .medium)
                    .foregroundStyle(tint)
            }
            .padding(.leading, 4)
            if let status {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: status.symbol)
                    Text(status.text)
                        .fixedSize(horizontal: false, vertical: true)
                    accessory
                }
                .font(.system(size: 12))
                .foregroundStyle(status.color)
            }
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 3),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(styles, id: \.self) { style in
                    StyleCard(
                        name: strings.translationStyleName(style),
                        example: strings.translationStyleExample(style),
                        note: strings.styleCardNote(style),
                        summary: strings.translationStyleSummary(style),
                        selected: model.translationStyle == style
                    ) {
                        withAnimation(.snappy(duration: 0.2)) {
                            model.selectTranslationStyle(style)
                        }
                    }
                }
            }
        }
    }
}

/// 一个风格一张卡片：名字、衬线斜体的示例译文、一句用途。选中时强调色描边、浅底，右上角一个勾。
private struct StyleCard: View {
    let name: String
    let example: String
    let note: String
    let summary: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.keyiGlassFrost) private var frost

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    KEYIMixedText.text(name, size: 14, weight: .semibold)
                    Spacer(minLength: 4)
                    if selected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8.5, weight: .bold))
                            .foregroundStyle(KEYIPalette.onAccent)
                            .frame(width: 16, height: 16)
                            .background(KEYIPalette.accent, in: Circle())
                            .transition(.scale(scale: 0.5).combined(with: .opacity))
                    }
                }
                .frame(minHeight: 16)
                // 示例 12.5pt 衬线斜体：比 14pt 的风格名轻一级，三行斜体也不压过中文名。
                Text(example)
                    .font(.system(size: 12.5, design: .serif).italic())
                    .foregroundStyle(KEYIPalette.trans)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top)
                KEYIMixedText.text(note, size: 11)
                    .foregroundStyle(KEYIPalette.ink2)
            }
            .foregroundStyle(KEYIPalette.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        selected ? KEYIPalette.accent : KEYIPalette.line2,
                        lineWidth: selected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(summary)
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.12)) { hovering = inside }
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var background: Color {
        if selected { return KEYIPalette.accentTint }
        return hovering ? KEYIPalette.surface : KEYIPalette.card(frost: frost)
    }
}
