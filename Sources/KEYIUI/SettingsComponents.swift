import SwiftUI

// 设置窗口各页共用的版面组件：页框、分组卡片、行、分隔线、标题。

/// 右边一页：标题写在红绿灯那一行（`subtitle` 跟在标题后面，如统计页的日期），下面是滚动内容，报告自然高度。
struct DetailPage<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var spacing: CGFloat = 10
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    PageTitle(title)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(KEYIPalette.ink3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(height: SettingsRootView.titleBarHeight)
                content
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            .foregroundStyle(KEYIPalette.ink)
            .modifier(ReportsHeight())
        }
    }
}

/// 一组设置：半透明圆角卡片（背后的磨砂透出来），行与行之间一条细线。
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
        }
        .keyiCard()
    }
}

extension View {
    /// 设置窗口里的卡片：半透明 surface（不透明度跟磨砂值走）、圆角 10、一圈 line 细线。
    func keyiCard(radius: CGFloat = 10) -> some View {
        modifier(KEYICard(radius: radius))
    }
}

private struct KEYICard: ViewModifier {
    let radius: CGFloat
    @Environment(\.keyiGlassFrost) private var frost

    func body(content: Content) -> some View {
        content
            .background(KEYIPalette.card(frost: frost), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(KEYIPalette.line, lineWidth: 1)
            }
    }
}

/// 卡片里的一行，一行就是一项：左边名称，名称后面可跟一句灰色短注（`note`，同一行），右边控件。
/// 长说明不再占第二行，放进鼠标悬停提示（`help`）；第二行只留状态和出错（`detail`）。
struct SettingsRow<Content: View>: View {
    let label: String
    var note: String? = nil
    var noteColor: Color = KEYIPalette.ink3
    var detail: String? = nil
    var detailColor: Color = KEYIPalette.ink2
    var help: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    KEYIMixedText.text(label, size: 13, weight: .medium)
                        .lineLimit(1)
                        .fixedSize()
                    if let note {
                        KEYIMixedText.text(note, size: 11.5)
                            .foregroundStyle(noteColor)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                if let detail {
                    KEYIMixedText.text(detail, size: 11.5)
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .modifier(OptionalHelp(text: help))
            content
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 38)
    }
}

/// 有说明才挂悬停提示。
struct OptionalHelp: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.help(text)
        } else {
            content
        }
    }
}

/// 组内分隔线：从文字左边开始，不贯穿卡片。
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(KEYIPalette.line).frame(height: 1).padding(.leading, 14)
    }
}

/// 组上方的小标题，用主题色字：换主题时页面上的字跟着变色。
struct SettingsSectionTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        KEYIMixedText.text(title, size: 12, weight: .semibold)
            .foregroundStyle(KEYIPalette.accentText)
            .padding(.leading, 4)
            .padding(.top, 4)
            .padding(.bottom, -4)
    }
}

/// 页首标题，写在红绿灯那一行。
struct PageTitle: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        KEYIMixedText.text(title, size: 17, weight: .semibold)
            .kerning(-0.2)
    }
}
