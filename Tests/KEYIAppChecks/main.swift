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

let store = TranslationSettingsStore(defaults: settingsDefaults)
expect(store.preferences.providerID == .appleSystem, "新用户默认使用系统翻译")
expect(store.preferences.targetLanguage == .english, "新用户默认英语")
expect(
    store.endpoint(for: .deepSeek) == "https://api.deepseek.com/chat/completions",
    "未保存端点应回退 DeepSeek 默认值"
)
expect(
    store.model(for: .volcengine) == "doubao-seed-translation-250915",
    "未保存模型应回退火山默认值"
)
expect(
    store.localModelEndpoint() == "http://127.0.0.1:1234/v1/chat/completions",
    "本地模型端点应回退 LM Studio 默认值"
)
expect(
    !store.hasStoredAPIConfiguration(for: .deepSeek),
    "未保存过的提供方应视为未配置"
)
expect(store.select(.deepSeek), "可用的提供方应能选择")

store.selectTargetLanguage(.japanese)
store.selectScene(.socialMedia)
store.selectEnglishStyle(.british)
let reloaded = TranslationSettingsStore(defaults: settingsDefaults)
expect(reloaded.preferences.providerID == .deepSeek, "提供方选择应持久化")
expect(reloaded.preferences.targetLanguage == .japanese, "目标语言应持久化")
expect(reloaded.preferences.scene == .socialMedia, "翻译场景应持久化")
expect(reloaded.preferences.englishStyle == .british, "英语风格应持久化")

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
let localConfiguration = try store.localModelConfiguration()
expect(localConfiguration.endpoint.port == 9123, "本地配置端口应保留")
expect(
    localConfiguration.loadKey == LocalModelCatalog.gemma4.defaultLoadKey,
    "本地配置应携带 Gemma 4 加载键"
)
settingsDefaults.removePersistentDomain(forName: settingsSuiteName)

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
let hotKeyStore = HotKeySettingsStore(defaults: hotKeyDefaults)
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

print("KEYI App checks passed: \(checkCount)")
