import Foundation
import Darwin
import KEYICore
import KEYITranslationClient
import KEYITranslationService
@testable import KEYIUI

if CommandLine.arguments.dropFirst().elementsEqual(["--installed-terminal-service-check"]) {
    do {
        let installedCheckCount = try await runInstalledTerminalServiceChecks()
        print("KEYI installed terminal service checks passed: \(installedCheckCount)")
        exit(EXIT_SUCCESS)
    } catch let error as InstalledTerminalServiceCheckFailure {
        FileHandle.standardError.write(
            Data("KEYI installed terminal service check failed: \(error.errorDescription ?? "details redacted")\n".utf8)
        )
        exit(EXIT_FAILURE)
    } catch {
        FileHandle.standardError.write(
            Data("KEYI installed terminal service check failed (details redacted).\n".utf8)
        )
        exit(EXIT_FAILURE)
    }
}

// 联网核对词库更新说明（只读 GitHub 公开接口，不下载词表、不装）：从旧的随包版本问上游。
// 不在默认检查里跑，避免检查依赖网络。
if CommandLine.arguments.dropFirst().elementsEqual(["--dictionary-update-live-check"]) {
    let old = KEYIDictionaryUpdate.Version(
        commit: "9e66b0729083b37d217312294f6d516c8d7234be",
        date: ISO8601DateFormatter().date(from: "2026-09-12T00:00:00Z")!
    )
    do {
        guard let offer = try await DictionaryUpdateModel.fetchOffer(since: old) else {
            print("offer=none")
            exit(EXIT_FAILURE)
        }
        print("to=\(offer.to.shortCommit) date=\(offer.to.date)")
        print("added=\(offer.change.added) removed=\(offer.change.removed)")
        print("addedSamples=\(offer.change.addedSamples.joined(separator: " "))")
        print("removedSamples=\(offer.change.removedSamples.joined(separator: " "))")
        for note in offer.notes { print("note=\(note)") }
        let current = try await DictionaryUpdateModel.fetchOffer(since: KEYIDictionaryUpdate.Version(
            commit: offer.to.commit, date: offer.to.date))
        print("fromLatest=\(current == nil ? "none" : "offer")")
        exit(EXIT_SUCCESS)
    } catch {
        print("failed=\(error.localizedDescription)")
        exit(EXIT_FAILURE)
    }
}

private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else {
        fatalError(message)
    }
}

// MARK: - 磨砂映射（2026-11-05 第二版：几何级数，0 端通透、100 端厚实，最通透时字读得清）

for dark in [false, true] {
    let floor = dark ? KEYIAppearanceSettings.tintFloorDark : KEYIAppearanceSettings.tintFloorLight
    let clear = KEYIAppearanceSettings.panelGlass(frost: 0, dark: dark)
    let thick = KEYIAppearanceSettings.panelGlass(frost: 100, dark: dark)
    expect(abs(clear.tintAlpha - floor) < 0.0001 && abs(clear.blurRadius - 3) < 0.0001, "磨砂 0：底色为下限、只略模糊")
    expect(abs(thick.tintAlpha - 0.96) < 0.0001 && abs(thick.blurRadius - 48) < 0.0001, "磨砂 100：底色 0.96、模糊 48")
    // 每拖 10 格，透出来的比例和模糊半径都按同一倍数变，前后半段一样看得出。
    var previous = clear
    for step in stride(from: 10.0, through: 100, by: 10) {
        let glass = KEYIAppearanceSettings.panelGlass(frost: step, dark: dark)
        let showRatio = (1 - glass.tintAlpha) / (1 - previous.tintAlpha)
        expect(showRatio < 0.85 && glass.blurRadius / previous.blurRadius > 1.3, "磨砂每 10 格都要看得出差别（\(step)）")
        previous = glass
    }
    let window = KEYIAppearanceSettings.windowGlass(frost: 0, dark: dark)
    expect(window.tintAlpha == clear.tintAlpha && window.blurRadius == clear.blurRadius, "设置窗口底色与面板同一套映射")
    expect(abs(window.cardAlpha - 0.2) < 0.0001
        && abs(KEYIAppearanceSettings.windowGlass(frost: 100, dark: dark).cardAlpha - 0.85) < 0.0001,
        "卡片底色跟磨砂从 0.2 到 0.85")
}
// 下限不能再往下压：亮色玻璃在黑底、暗色玻璃在白底上，正文 ≥ 4.5:1、译文约 3:1（见 KEYIAppearance 注释）。
expect(KEYIAppearanceSettings.tintFloorLight >= 0.63 && KEYIAppearanceSettings.tintFloorDark >= 0.73, "底色下限保证最通透时读得清")

// MARK: - TranslationSettingsStore（注入独立 defaults suite，不碰用户真实偏好）

let settingsSuiteName = "KEYIAppChecks-\(UUID().uuidString)"
let settingsDefaults = UserDefaults(suiteName: settingsSuiteName)!

let store = TranslationSettingsStore(
    defaults: settingsDefaults
)
expect(store.preferences.providerID == .appleSystem, "新用户默认使用系统翻译")
expect(store.preferences.targetLanguage == .english, "新用户默认英语")
expect(
    store.endpoint(for: .deepSeek) == "https://api.deepseek.com/chat/completions",
    "未保存端点应回退 DeepSeek 默认值"
)
expect(
    store.model(for: .volcengine) == "doubao-seed-1-6-250615",
    "未保存模型应回退火山 Chat Completions 默认值"
)
expect(store.preferences.interfaceLanguage == .automatic, "新用户默认跟随系统界面语言")
expect(store.localModelTier() == nil, "新用户没有选过本地模型档位")
expect(!store.hasLocalModelMigrationNotice, "新用户没有迁移提示")
expect(
    !store.hasStoredAPIConfiguration(for: .deepSeek),
    "未保存过的提供方应视为未配置"
)
expect(store.select(.deepSeek), "可用的提供方应能选择")

store.selectTargetLanguage(.japanese)
store.selectScene(.socialMedia)
store.selectEnglishStyle(.british)
store.selectInterfaceLanguage(.english)
let reloaded = TranslationSettingsStore(defaults: settingsDefaults)
expect(reloaded.preferences.providerID == .deepSeek, "提供方选择应持久化")
expect(reloaded.preferences.targetLanguage == .japanese, "目标语言应持久化")
expect(reloaded.preferences.scene == .socialMedia, "翻译场景应持久化")
expect(reloaded.preferences.englishStyle == .british, "英语风格应持久化")
expect(reloaded.preferences.interfaceLanguage == .english, "界面语言应持久化")

// 校验失败的路径在触碰钥匙串之前抛出，不会写入任何凭据。
do {
    try store.saveAPIConfiguration(
        for: .deepSeek,
        apiKey: "test-secret",
        endpoint: "http://insecure.test/v1/chat/completions",
        model: "deepseek-chat"
    )
    expect(false, "非 HTTPS 端点必须被拒绝")
} catch TranslationSettingsError.invalidEndpoint {
    expect(true, "非 HTTPS 端点被拒绝")
}
do {
    try store.saveAPIConfiguration(
        for: .deepSeek,
        apiKey: "test-secret",
        endpoint: "https://example.test/v1/chat/completions",
        model: " "
    )
    expect(false, "空模型名必须被拒绝")
} catch TranslationSettingsError.missingModel {
    expect(true, "空模型名被拒绝")
}
store.selectLocalModelTier(.standard)
expect(store.localModelTier() == .standard, "本地模型档位应持久化")
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

// 旧版 LM Studio 配置：删掉地址和模型名；正在用本地模型的切回系统翻译，并只提示一次。
// MARK: - 翻译风格：用户只选风格，引擎按风格现算

let styleSuiteName = "KEYIAppChecks-style-\(UUID().uuidString)"
let styleDefaults = UserDefaults(suiteName: styleSuiteName)!
let styleStore = TranslationSettingsStore(defaults: styleDefaults)
expect(styleStore.translationStyle() == .natural, "新用户默认风格是「自然」")
expect(styleDefaults.string(forKey: KEYITranslationStyle.storageKey) == "natural", "默认风格应写入偏好")
styleStore.selectTranslationStyle(.british)
expect(TranslationSettingsStore(defaults: styleDefaults).translationStyle() == .british, "风格选择应持久化")
styleDefaults.removePersistentDomain(forName: styleSuiteName)

expect(
    TranslationStyleRouting.migratedStyle(
        from: TranslationPreferences(providerID: .deepSeek, scene: .dailyChat, englishStyle: .blackAmerican)
    ) == .blackAmerican,
    "旧版云端黑人英语用户迁移到黑人英语口语"
)
expect(
    TranslationStyleRouting.migratedStyle(
        from: TranslationPreferences(providerID: .localModel, scene: .dailyChat, englishStyle: .blackAmerican)
    ) == .natural,
    "旧版本地模型用户迁移到「自然」，不被悄悄改走云端"
)
expect(
    TranslationStyleRouting.migratedStyle(from: TranslationPreferences(providerID: .qwen, scene: .business)) == .business,
    "旧版商务场景迁移到正式商务"
)

let naturalLocal = TranslationStyleRouting.route(for: .natural, localModelReady: true, cloudProvider: .deepSeek)
expect(naturalLocal.providerID == .localModel && !naturalLocal.usesNaturalInstead, "自然风格用本地模型，即使配了云端")
expect(
    TranslationStyleRouting.route(for: .business, localModelReady: false, cloudProvider: nil).providerID == .appleSystem,
    "本地模型没下载时本地风格暂用苹果翻译"
)
let businessRoute = TranslationStyleRouting.route(for: .business, localModelReady: true, cloudProvider: nil)
expect(businessRoute.scene == .business && businessRoute.englishStyle == .automatic, "正式商务带商务场景、不带口语风格")
let blackCloud = TranslationStyleRouting.route(for: .blackAmerican, localModelReady: true, cloudProvider: .deepSeek)
expect(
    blackCloud.providerID == .deepSeek && blackCloud.englishStyle == .blackAmerican && blackCloud.scene == .automatic,
    "黑人英语口语走已配置的云端"
)
let blackFallback = TranslationStyleRouting.route(for: .blackAmerican, localModelReady: true, cloudProvider: nil)
expect(
    blackFallback.providerID == .localModel && blackFallback.usesNaturalInstead
        && blackFallback.englishStyle == .automatic,
    "云端没配好时云端风格先按「自然」走本地并说明"
)
expect(
    KEYITranslationStyle.allCases.filter(\.usesCloud) == [.americanCasual, .blackAmerican, .british],
    "只有三种地道口语要联网"
)

let cloudSuiteName = "KEYIAppChecks-cloud-\(UUID().uuidString)"
let cloudDefaults = UserDefaults(suiteName: cloudSuiteName)!
let cloudStore = TranslationSettingsStore(defaults: cloudDefaults)
expect(cloudStore.preferredCloudProvider { _ in false } == nil, "没配云端时没有云端服务")
expect(cloudStore.preferredCloudProvider { $0 == .qwen } == .qwen, "按清单取第一个已配置的云端服务")
expect(cloudStore.select(.xAI), "可以指定云端服务")
expect(
    cloudStore.preferredCloudProvider { $0 == .qwen || $0 == .xAI } == .xAI,
    "上次指定的云端服务已配置时优先用它"
)
cloudDefaults.removePersistentDomain(forName: cloudSuiteName)

let legacySuiteName = "KEYIAppChecks-legacy-\(UUID().uuidString)"
let legacyDefaults = UserDefaults(suiteName: legacySuiteName)!
legacyDefaults.set(
    try JSONEncoder().encode(TranslationPreferences(providerID: .localModel)),
    forKey: "translation.preferences"
)
legacyDefaults.set("http://127.0.0.1:1234/v1/chat/completions", forKey: "translation.local.endpoint")
legacyDefaults.set("keyi-gemma4", forKey: "translation.local.gemma4.model")
let migrated = TranslationSettingsStore(defaults: legacyDefaults)
expect(migrated.preferences.providerID == .appleSystem, "旧 LM Studio 用户应切回苹果系统翻译")
expect(migrated.hasLocalModelMigrationNotice, "迁移后应留一次提示")
expect(
    legacyDefaults.string(forKey: "translation.local.endpoint") == nil
        && legacyDefaults.string(forKey: "translation.local.gemma4.model") == nil,
    "旧 LM Studio 地址和模型名应删除"
)
migrated.clearLocalModelMigrationNotice()
let migratedAgain = TranslationSettingsStore(defaults: legacyDefaults)
expect(!migratedAgain.hasLocalModelMigrationNotice, "看过的提示不再出现")
migratedAgain.selectLocalModelTier(.light)
expect(migratedAgain.select(.localModel), "选过档位后可以用本地模型")
let keptLocal = TranslationSettingsStore(defaults: legacyDefaults)
expect(keptLocal.preferences.providerID == .localModel, "选过 Hy-MT2 档位的本地模型用户不被迁移")
expect(!keptLocal.hasLocalModelMigrationNotice, "不迁移就不提示")
legacyDefaults.removePersistentDomain(forName: legacySuiteName)

// MARK: - HotKeyConfiguration / HotKeySettingsStore

expect(HotKeyConfiguration.default.isValid, "默认快捷键 ⌥T 应有效")
expect(HotKeyConfiguration.default.displayName == "⌥T", "默认快捷键显示名应为 ⌥T")
let encodedHotKey = try! JSONEncoder().encode(HotKeyConfiguration.default)
let decodedHotKey = try! JSONDecoder().decode(
    HotKeyConfiguration.self,
    from: encodedHotKey
)
expect(decodedHotKey == HotKeyConfiguration.default, "快捷键配置应可往返编解码")

let hotKeySuiteName = "KEYIAppChecks-HotKey-\(UUID().uuidString)"
let hotKeyDefaults = UserDefaults(suiteName: hotKeySuiteName)!
let hotKeyStore = HotKeySettingsStore(
    defaults: hotKeyDefaults
)
expect(
    hotKeyStore.configuration == .default,
    "无保存数据时应回退默认快捷键"
)
try hotKeyStore.save(HotKeyConfiguration.default)
expect(
    hotKeyStore.configuration == HotKeyConfiguration.default,
    "快捷键保存后读取应一致"
)
hotKeyDefaults.set(Data("{}".utf8), forKey: "hotKeyConfiguration")
expect(
    HotKeySettingsStore(defaults: hotKeyDefaults).configuration == .default,
    "无法解码的数据应回退默认快捷键"
)
hotKeyDefaults.set(
    Data("{\"keyCode\":84,\"modifiers\":0,\"keyName\":\"T\"}".utf8),
    forKey: "hotKeyConfiguration"
)
expect(
    HotKeySettingsStore(defaults: hotKeyDefaults).configuration == .default,
    "无修饰键的非法配置应回退默认快捷键"
)
hotKeyDefaults.removePersistentDomain(forName: hotKeySuiteName)

// MARK: - Async write-back cancellation gate

var emittedWriteAfterCancellation = false
do {
    try TranslationWriteBackGate.requireActive { false }
    emittedWriteAfterCancellation = true
} catch is CancellationError {
    // The request was cleared before a simulated input event could be emitted.
}
expect(!emittedWriteAfterCancellation, "已取消请求不得继续发出回写事件")

var writeRequestIsCurrent = true
var emittedDeferredWrite = false
let deferredWrite = Task { @MainActor in
    try? await Task.sleep(for: .milliseconds(20))
    do {
        try TranslationWriteBackGate.requireActive { writeRequestIsCurrent }
        emittedDeferredWrite = true
    } catch is CancellationError {
        // Recovery cleared the request during an asynchronous wait.
    } catch {
        fatalError("回写门控返回了非取消错误：\(error)")
    }
}
writeRequestIsCurrent = false
await deferredWrite.value
expect(!emittedDeferredWrite, "异步等待后已取消请求不得发出回写事件")

// MARK: - CredentialStore（真实钥匙串往返；使用专用测试账号并在结束与失败前清理）

let credentialAccount = "test.keyi.checks"
try CredentialStore.delete(account: credentialAccount)
let initialRead: String? = try CredentialStore.read(account: credentialAccount)
expect(initialRead == nil, "清理后读取应为空")

try CredentialStore.save("secret-1", account: credentialAccount)
let savedRead: String? = try CredentialStore.read(account: credentialAccount)
expect(savedRead == "secret-1", "钥匙串应可保存并读取")

try CredentialStore.save("secret-2", account: credentialAccount)
let updatedRead: String? = try CredentialStore.read(account: credentialAccount)
expect(updatedRead == "secret-2", "重复保存应更新而非报错")

do {
    try CredentialStore.save("x", account: "非法 账号")
    expect(false, "非法账户名必须被拒绝")
} catch CredentialStoreError.invalidAccount {
    expect(true, "非法账户名被拒绝")
}

try CredentialStore.delete(account: credentialAccount)
let deletedRead: String? = try CredentialStore.read(account: credentialAccount)
expect(deletedRead == nil, "删除后条目应消失")

// MARK: - 云端提供方错误按界面语言渲染

let apiError = APITranslationError.httpFailure(
    providerID: .qwen,
    statusCode: 401,
    message: "bad key"
)
expect(
    renderedAPIMessage(apiError, language: .simplifiedChinese)
        == "通义千问 请求失败（HTTP 401：bad key）",
    "中文界面应渲染中文错误"
)
expect(
    renderedAPIMessage(apiError, language: .english)
        == "Qwen request failed (HTTP 401: bad key)",
    "英文界面应渲染英文错误"
)
expect(
    renderedAPIMessage(.emptyResponse(providerID: .relay), language: .english)
        == "Custom Service returned no translation",
    "空译文错误应带提供方名"
)

let englishStrings = InterfaceStrings(language: .english)
expect(englishStrings.settings == "Settings...", "设置命令应保留省略号")
expect(englishStrings.settingsTitle == "Settings", "设置窗口标题不应带省略号")
expect(englishStrings.translationMethod == "Translation", "英文翻译服务菜单应使用 Translation")
expect(englishStrings.targetLanguage == "Language", "英文目标语言应使用 Language")
expect(englishStrings.scene == "Context", "英文使用场景应使用 Context")
expect(englishStrings.style == "Style", "英文表达风格应使用 Style")
expect(englishStrings.styleName(.westCoast) == "Casual US", "轻松美式不应承诺具体地域身份")
expect(englishStrings.languageName(.chinese) == "Chinese", "英文界面应显示 Chinese")

/// 在指定界面语言下渲染错误，避免依赖测试机的系统语言。
@MainActor
private func renderedAPIMessage(
    _ error: APITranslationError,
    language: InterfaceLanguage
) -> String {
    let saved = UserDefaults.standard.string(forKey: InterfaceLanguageStorage.key)
    UserDefaults.standard.set(language.rawValue, forKey: InterfaceLanguageStorage.key)
    defer {
        if let saved {
            UserDefaults.standard.set(saved, forKey: InterfaceLanguageStorage.key)
        } else {
            UserDefaults.standard.removeObject(forKey: InterfaceLanguageStorage.key)
        }
    }
    return error.localizedMessage
}

checkCount += try await runAppFlowChecks()
checkCount += try await runTerminalDraftEditorChecks()
checkCount += runTerminalDraftObservationChecks()
checkCount += try await runLocalModelDownloaderChecks()
checkCount += try await runLocalModelServerChecks()
checkCount += try await runSpeechTranscriptionChecks()
print("KEYI App checks passed: \(checkCount)")
