import Foundation

/// 包在大模型翻译外面：译成英文成功后，把这句原文和译文交给个人术语表暂存（用户没打开时什么都不存）；
/// 攒够一批就在后台请同一个服务提炼固定词对。不改译文，也不让提炼拖慢这次翻译。
public struct GlossaryCollectingProvider: TranslationProvider {
    private let inner: OpenAICompatibleTranslationProvider
    private let glossary: PersonalGlossary

    public init(inner: OpenAICompatibleTranslationProvider, glossary: PersonalGlossary = .standard) {
        self.inner = inner
        self.glossary = glossary
    }

    public var id: TranslationProviderID { inner.id }

    public func translate(_ request: TextTranslationRequest) async throws -> String {
        let translation = try await inner.translate(request)
        if request.targetLanguage == .english, glossary.isEnabled {
            let pending = glossary.collect(.init(source: request.sourceText, translation: translation))
            if pending >= PersonalGlossary.batchSize {
                let inner = inner
                let glossary = glossary
                Task.detached(priority: .utility) {
                    try? await Self.extract(with: inner, into: glossary)
                }
            }
        }
        return translation
    }

    /// 取走暂存的整句提炼一次，合并进术语表。返回新增或更新的条数。
    @discardableResult
    public static func extract(with provider: OpenAICompatibleTranslationProvider, into glossary: PersonalGlossary) async throws -> Int {
        let samples = glossary.takePending()
        guard !samples.isEmpty else { return 0 }
        let candidates = try await provider.extractGlossary(from: samples)
        return glossary.merge(candidates, from: samples)
    }
}
