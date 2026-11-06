import Combine
import KEYICore
import SwiftUI

/// 个人术语表的设置窗口状态：开关、词条、暂存句数。数据在 `PersonalGlossary` 的文件里，
/// 翻译服务进程也在写，所以设置页显示期间定时重读。
@MainActor
final class PersonalGlossaryModel: ObservableObject {
    static let shared = PersonalGlossaryModel()

    @Published private(set) var enabled = false
    @Published private(set) var terms: [PersonalGlossary.Term] = []
    @Published private(set) var pendingCount = 0
    @Published private(set) var busy = false
    @Published private(set) var message: String?

    private let glossary = PersonalGlossary.standard

    func reload() {
        enabled = glossary.isEnabled
        terms = glossary.terms
        pendingCount = glossary.pendingCount
    }

    func setEnabled(_ value: Bool) {
        glossary.setEnabled(value)
        message = nil
        reload()
    }

    func remove(_ term: PersonalGlossary.Term) {
        glossary.remove(source: term.source)
        reload()
    }

    func clear() {
        glossary.clear()
        message = nil
        reload()
    }

    /// 不等攒够一批，现在就用正在用的大模型服务整理一次。
    func extractNow(model: AppModel) {
        let strings = model.strings
        busy = true
        Task {
            defer { busy = false; reload() }
            guard let provider = await model.glossaryExtractionProvider() else {
                message = strings.glossaryNeedsCloud
                return
            }
            do {
                let added = try await GlossaryCollectingProvider.extract(with: provider, into: glossary)
                message = strings.glossaryExtracted(added)
            } catch {
                message = strings.glossaryExtractFailed
            }
        }
    }
}

extension AppModel {
    /// 正在用的大模型服务；没配好时为 nil。
    func glossaryExtractionProvider() async -> OpenAICompatibleTranslationProvider? {
        guard let providerID = cloudProviderInUse,
              let configuration = try? await apiConfigurationForGlossary(providerID)
        else { return nil }
        return OpenAICompatibleTranslationProvider(
            configuration: configuration,
            usageRecorder: { APIUsageLedger.standard.record(providerID: $0, usage: $1) }
        )
    }
}

/// 「高级 › 翻译」组里的「个人术语表」一行。
struct PersonalGlossaryRow: View {
    @ObservedObject var model: AppModel
    @ObservedObject var glossary: PersonalGlossaryModel = .shared
    @State private var showingTerms = false
    @State private var confirmingClear = false
    @State private var showingWhy = false
    private let refresh = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        let strings = model.strings
        // 「翻译」组里的一行：名称后面是条数，右边查看、清空和开关；做什么、为什么再发一次放进 ⓘ。
        SettingsRow(
            label: strings.glossaryTitle,
            note: strings.glossarySummary(terms: glossary.terms.count, pending: glossary.pendingCount, enabled: glossary.enabled),
            detail: glossary.message,
            help: strings.glossaryToggle
        ) {
            HStack(spacing: 8) {
                if glossary.busy { ProgressView().controlSize(.small) }
                if glossary.enabled, glossary.pendingCount > 0 {
                    Button(strings.glossaryExtractNow) { glossary.extractNow(model: model) }
                        .disabled(glossary.busy)
                }
                if !glossary.terms.isEmpty {
                    Button(strings.glossaryShow) { showingTerms = true }
                }
                if !glossary.terms.isEmpty || glossary.pendingCount > 0 {
                    Button(strings.glossaryClear) { confirmingClear = true }
                }
                Button {
                    showingWhy.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(KEYIPalette.ink3)
                }
                .buttonStyle(.borderless)
                .help(strings.glossaryWhyTitle)
                .accessibilityLabel(strings.glossaryWhyTitle)
                .popover(isPresented: $showingWhy, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(strings.glossaryToggle).font(.headline)
                        Text(strings.glossaryDescription)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(strings.glossaryWhyTitle).font(.headline).padding(.top, 4)
                        Text(strings.glossaryWhyBody)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .padding(14)
                    .frame(width: 340)
                }
                Toggle(strings.glossaryToggle, isOn: Binding(
                    get: { glossary.enabled },
                    set: { glossary.setEnabled($0) }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .help(strings.glossaryToggle)
            }
        }
        .onAppear { glossary.reload() }
        .onReceive(refresh) { _ in glossary.reload() }
        .sheet(isPresented: $showingTerms) { PersonalGlossaryList(strings: strings, glossary: glossary) }
        .alert(strings.glossaryClearTitle, isPresented: $confirmingClear) {
            Button(strings.glossaryClear, role: .destructive) { glossary.clear() }
            Button(strings.cancel, role: .cancel) {}
        } message: {
            Text(strings.glossaryClearMessage)
        }
    }
}

/// 查看与删除单条。
private struct PersonalGlossaryList: View {
    let strings: InterfaceStrings
    @ObservedObject var glossary: PersonalGlossaryModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(strings.glossaryTitle).font(.headline)
            List {
                ForEach(glossary.terms, id: \.source) { term in
                    HStack {
                        Text(term.source)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                        Text(term.target).foregroundStyle(.secondary)
                        Spacer()
                        if term.count > 1 { Text("×\(term.count)").font(.caption).foregroundStyle(.tertiary) }
                        Button {
                            glossary.remove(term)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help(strings.glossaryRemove)
                    }
                }
            }
            .frame(minWidth: 420, minHeight: 300)
            HStack {
                Spacer()
                Button(strings.done) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
}
