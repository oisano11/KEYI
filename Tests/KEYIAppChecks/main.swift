import Foundation
import KEYICore
@testable import KEYIUI

private var checkCount = 0

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    checkCount += 1
    guard condition() else {
        fatalError(message)
    }
}

// MARK: - TranslationSettingsStore（注入独立 defaults suite，不碰用户真实偏好）

let settingsSuiteName = "KEYIAppChecks-\(UUID().uuidString)"
let settingsDefaults = UserDefaults(suiteName: settingsSuiteName)!

let store = TranslationSettingsStore(
    defaults: settingsDefaults,
    legacyDefaults: nil
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
expect(
    store.localModelEndpoint() == "http://127.0.0.1:1234/v1/chat/completions",
    "本地模型端点应回退 LM Studio 默认值"
)
expect(store.configuredLocalModelEndpoint() == nil, "未配置本地模型时设置页地址应为空")
expect(store.configuredLocalModelName() == nil, "未配置本地模型时设置页模型名应为空")
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
do {
    try store.saveLocalModelConfiguration(endpoint: "https://example.test", model: "m")
    expect(false, "本地模型端点必须是本机地址")
} catch TranslationSettingsError.invalidLocalEndpoint {
    expect(true, "非本机端点被拒绝")
}
try store.saveLocalModelConfiguration(
    endpoint: "http://127.0.0.1:9123/v1/chat/completions",
    model: " local-model "
)
expect(store.localModelName() == "local-model", "本地模型名应去空白保存")
expect(
    store.configuredLocalModelEndpoint() == "http://127.0.0.1:9123/v1/chat/completions",
    "已配置本地模型时设置页应显示保存的地址"
)
expect(store.configuredLocalModelName() == "local-model", "已配置本地模型时设置页应显示保存的模型名")
let localConfiguration = try store.localModelConfiguration()
expect(localConfiguration.endpoint.port == 9123, "本地配置端口应保留")
expect(
    localConfiguration.loadKey == LocalModelCatalog.gemma4.defaultLoadKey,
    "本地配置应携带 Gemma 4 加载键"
)
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

let legacyTestSourceSuiteName = "KEYIAppChecks-Legacy-Test-Source-\(UUID().uuidString)"
let legacyTestSuiteName = "KEYIAppChecks-Legacy-Test-\(UUID().uuidString)"
let legacyTestSourceDefaults = UserDefaults(suiteName: legacyTestSourceSuiteName)!
let legacyTestDefaults = UserDefaults(suiteName: legacyTestSuiteName)!
legacyTestSourceDefaults.set(
    LocalModelCatalog.gemma4.defaultEndpoint,
    forKey: "translation.local.endpoint"
)
legacyTestSourceDefaults.set(
    LocalModelCatalog.gemma4.defaultModel,
    forKey: "translation.local.gemma4.model"
)
let cleanedLegacyTestStore = TranslationSettingsStore(
    defaults: legacyTestDefaults,
    legacyDefaults: legacyTestSourceDefaults
)
expect(
    cleanedLegacyTestStore.configuredLocalModelEndpoint() == nil
        && cleanedLegacyTestStore.configuredLocalModelName() == nil,
    "迁移进来的旧测试本地模型配置应自动清除"
)
try cleanedLegacyTestStore.saveLocalModelConfiguration(
    endpoint: LocalModelCatalog.gemma4.defaultEndpoint,
    model: LocalModelCatalog.gemma4.defaultModel
)
let reloadedLegacyTestStore = TranslationSettingsStore(
    defaults: legacyTestDefaults,
    legacyDefaults: legacyTestSourceDefaults
)
expect(
    reloadedLegacyTestStore.configuredLocalModelEndpoint() == LocalModelCatalog.gemma4.defaultEndpoint
        && reloadedLegacyTestStore.configuredLocalModelName() == LocalModelCatalog.gemma4.defaultModel,
    "用户主动保存默认本地模型配置后不应在下次启动被删除"
)
legacyTestSourceDefaults.removePersistentDomain(forName: legacyTestSourceSuiteName)
legacyTestDefaults.removePersistentDomain(forName: legacyTestSuiteName)

// MARK: - HanYi -> KEYI UserDefaults migration

let legacySettingsSuiteName = "KEYIAppChecks-Legacy-\(UUID().uuidString)"
let migratedSettingsSuiteName = "KEYIAppChecks-Migrated-\(UUID().uuidString)"
let currentSettingsSuiteName = "KEYIAppChecks-Current-\(UUID().uuidString)"
let legacySettingsDefaults = UserDefaults(suiteName: legacySettingsSuiteName)!
let migratedSettingsDefaults = UserDefaults(suiteName: migratedSettingsSuiteName)!
let currentSettingsDefaults = UserDefaults(suiteName: currentSettingsSuiteName)!

let legacyPreferences = TranslationPreferences(
    providerID: .qwen,
    targetLanguage: .japanese,
    scene: .business,
    englishStyle: .british
)
legacySettingsDefaults.set(
    try! JSONEncoder().encode(legacyPreferences),
    forKey: "translation.preferences"
)
legacySettingsDefaults.set(
    "https://legacy.example.test/v1/chat/completions",
    forKey: "translation.api.qwen.endpoint"
)
legacySettingsDefaults.set(
    "legacy-qwen",
    forKey: "translation.api.qwen.model"
)
legacySettingsDefaults.set(
    "http://127.0.0.1:9123/v1/chat/completions",
    forKey: "translation.local.endpoint"
)
legacySettingsDefaults.set(
    "legacy-local-model",
    forKey: "translation.local.gemma4.model"
)

let migratedStore = TranslationSettingsStore(
    defaults: migratedSettingsDefaults,
    legacyDefaults: legacySettingsDefaults
)
expect(migratedStore.preferences == legacyPreferences, "旧版翻译偏好应迁移到 KEYI 域")
expect(
    migratedStore.endpoint(for: .qwen) == "https://legacy.example.test/v1/chat/completions",
    "旧版 API Endpoint 应迁移到 KEYI 域"
)
expect(migratedStore.model(for: .qwen) == "legacy-qwen", "旧版模型名应迁移到 KEYI 域")
expect(
    migratedStore.localModelEndpoint() == "http://127.0.0.1:9123/v1/chat/completions",
    "旧版本地模型 Endpoint 应迁移到 KEYI 域"
)
expect(migratedStore.localModelName() == "legacy-local-model", "旧版本地模型名应迁移到 KEYI 域")

let currentPreferences = TranslationPreferences(providerID: .deepSeek)
currentSettingsDefaults.set(
    try! JSONEncoder().encode(currentPreferences),
    forKey: "translation.preferences"
)
currentSettingsDefaults.set(
    "https://current.example.test/v1/chat/completions",
    forKey: "translation.api.qwen.endpoint"
)
let currentStore = TranslationSettingsStore(
    defaults: currentSettingsDefaults,
    legacyDefaults: legacySettingsDefaults
)
expect(currentStore.preferences == currentPreferences, "已有 KEYI 翻译偏好必须优先")
expect(
    currentStore.endpoint(for: .qwen) == "https://current.example.test/v1/chat/completions",
    "已有 KEYI API Endpoint 必须优先"
)

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
    defaults: hotKeyDefaults,
    legacyDefaults: nil
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
    HotKeySettingsStore(defaults: hotKeyDefaults, legacyDefaults: nil).configuration == .default,
    "无法解码的数据应回退默认快捷键"
)
hotKeyDefaults.set(
    Data("{\"keyCode\":84,\"modifiers\":0,\"keyName\":\"T\"}".utf8),
    forKey: "hotKeyConfiguration"
)
expect(
    HotKeySettingsStore(defaults: hotKeyDefaults, legacyDefaults: nil).configuration == .default,
    "无修饰键的非法配置应回退默认快捷键"
)
hotKeyDefaults.removePersistentDomain(forName: hotKeySuiteName)

let legacyHotKeyData = try! JSONEncoder().encode(HotKeyConfiguration.default)
legacySettingsDefaults.set(legacyHotKeyData, forKey: "hotKeyConfiguration")
let migratedHotKeyStore = HotKeySettingsStore(
    defaults: migratedSettingsDefaults,
    legacyDefaults: legacySettingsDefaults
)
expect(migratedHotKeyStore.configuration == .default, "旧版快捷键应迁移到 KEYI 域")
expect(
    migratedSettingsDefaults.data(forKey: "hotKeyConfiguration") == legacyHotKeyData,
    "迁移后的 KEYI 快捷键数据应保留"
)

let alternateHotKey = try! JSONDecoder().decode(
    HotKeyConfiguration.self,
    from: Data("{\"keyCode\":11,\"modifiers\":2048,\"keyName\":\"B\"}".utf8)
)
let currentHotKeyData = try! JSONEncoder().encode(alternateHotKey)
currentSettingsDefaults.set(currentHotKeyData, forKey: "hotKeyConfiguration")
let currentHotKeyStore = HotKeySettingsStore(
    defaults: currentSettingsDefaults,
    legacyDefaults: legacySettingsDefaults
)
expect(currentHotKeyStore.configuration == alternateHotKey, "已有 KEYI 快捷键必须优先")

legacySettingsDefaults.removePersistentDomain(forName: legacySettingsSuiteName)
migratedSettingsDefaults.removePersistentDomain(forName: migratedSettingsSuiteName)
currentSettingsDefaults.removePersistentDomain(forName: currentSettingsSuiteName)

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

// MARK: - 旧明文凭据自动迁移

let legacyDirectory = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("HanYi/Credentials-v1", isDirectory: true)
try FileManager.default.createDirectory(
    at: legacyDirectory,
    withIntermediateDirectories: true
)
let legacyFile = legacyDirectory
    .appendingPathComponent("\(credentialAccount).secret")
try Data("legacy-secret".utf8).write(to: legacyFile)

let migrated: String? = try CredentialStore.read(account: credentialAccount)
expect(migrated == "legacy-secret", "旧明文凭据应自动迁移到钥匙串")
expect(
    !FileManager.default.fileExists(atPath: legacyFile.path),
    "迁移后应删除明文文件"
)
try CredentialStore.delete(account: credentialAccount)

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

print("KEYI App checks passed: \(checkCount)")
