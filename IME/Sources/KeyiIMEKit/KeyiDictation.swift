import AppKit

// 语音输入（契约 2026-11-07）：没在打拼音时按住右 ⌥ 说话，松开定稿。本文件只放与会话无关的部分：
// 识别引擎接口、右 ⌥ 的按下/松开判定、识别文字整理、诊断替身。一次录音怎么选云端或本机见
// `KeyiLiveDictation.swift`，本机识别是 KEYI 自带的 SenseVoice-Small（`KeyiSenseVoice.swift`）。
// 会话怎么把文字画进下划线段、交给自动翻译，见 `InputSession+Dictation.swift`。

/// 这次录音没开始或中途失败的原因；会话据此提示一行，不写任何文字。
enum KeyiDictationFailure: Equatable {
    /// 刚弹出系统的麦克风授权，这次不录。
    case microphonePending
    /// 麦克风权限被关掉了。
    case microphoneDenied
    /// 包里的识别模型或运行库缺失、加载失败。
    case modelUnavailable
    /// 麦克风起不来。
    case unavailable

    var message: String {
        switch self {
        case .microphonePending:
            "允许 KEYI 输入法使用麦克风后，再按住右 ⌥ 说话"
        case .microphoneDenied:
            "麦克风权限没开：系统设置 → 隐私与安全性 → 麦克风"
        case .modelUnavailable:
            "语音识别模型没能加载，请重新安装 KEYI 输入法"
        case .unavailable:
            "麦克风没能启动"
        }
    }
}

/// 一次录音。`start` 后不断用 `onText` 报此刻整段的识别文字，`onEngine` 报这次用哪个引擎（可能报
/// 不止一次：云端出错改用本机时再报一次并带提示），`finish` 停止收音、识别完整段后给出定稿；
/// `cancel` 立即停止、什么都不再给。回调都在主线程，方法也只在主线程调用。
protocol KeyiDictationEngine: AnyObject {
    func start(
        onText: @escaping (String) -> Void,
        onEngine: @escaping (KeyiDictationEngineInfo) -> Void,
        onFailure: @escaping (KeyiDictationFailure) -> Void
    )
    func finish(_ completion: @escaping (String) -> Void)
    func cancel()
}

enum KeyiDictationEngines {
    static func makeDefault() -> KeyiDictationEngine? {
        KeyiLiveDictationEngine()
    }
}

/// 右 ⌥（Option）。flagsChanged 事件不吞，照常交给应用。
enum KeyiDictationKey {
    static let rightOption: UInt16 = 61
    /// NX_DEVICELALTKEYMASK / NX_DEVICERALTKEYMASK：区分左右 ⌥ 的设备位。
    private static let leftOptionDeviceBit: UInt = 0x20
    private static let rightOptionDeviceBit: UInt = 0x40
    static let modifiers: NSEvent.ModifierFlags = [.shift, .control, .option, .command, .function]

    /// 右 ⌥ 的 flagsChanged：true 按下，false 松开；别的键返回 nil。
    static func rightOptionIsDown(keyCode: UInt16, rawFlags: UInt) -> Bool? {
        guard keyCode == rightOption else { return nil }
        if rawFlags & (leftOptionDeviceBit | rightOptionDeviceBit) != 0 {
            return rawFlags & rightOptionDeviceBit != 0
        }
        // 不带左右设备位的事件（诊断替身、部分宿主）：只看 ⌥ 还在不在。
        return NSEvent.ModifierFlags(rawValue: rawFlags).contains(.option)
    }
}

enum KeyiDictationText {
    /// 去掉首尾空白；汉字、中文标点旁边的空格去掉，英文单词之间的空格留一个。
    static func normalized(_ text: String) -> String {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = ""
        for (index, character) in characters.enumerated() {
            guard character.isWhitespace else {
                result.append(character)
                continue
            }
            guard let previous = result.last, !previous.isWhitespace, !isWide(previous) else { continue }
            let next = characters[(index + 1)...].first { !$0.isWhitespace }
            guard let next, !isWide(next) else { continue }
            result.append(" ")
        }
        return result
    }

    /// 汉字与全角标点（CJK 统一汉字、CJK 标点、全角字符）。
    static func isWide(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x2E80...0x9FFF, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFFEF, 0x20000...0x2FA1F:
                true
            default:
                false
            }
        }
    }
}

/// 识别文字逐字流出。识别器约每半秒给一次整段，直接换上去就是一块一块地跳；这里记住最新的整段
/// （`target`）和已经露出的字数：露出的部分识别改了就原地换掉（字数不变），新来的字按积压多少匀速
/// 一个个露出来，赶在下一次识别前露完。松开后剩下的字更快露完再定稿。
struct KeyiDictationReveal {
    /// 说话中两次识别大约隔多久（识别间隔加上等下一次检查、识别用的时间）。
    static let listeningWindow: TimeInterval = KeyiLiveDictationEngine.liveInterval + 0.05
    /// 松开后剩下的字在这段时间里露完。
    static let finishingWindow: TimeInterval = 0.25
    /// 字少时也不慢过这个，字多时也不快过这个（秒/字）。
    static let slowestStep: TimeInterval = 0.12
    static let fastestStep: TimeInterval = 0.02

    private(set) var target: [Character] = []
    private(set) var revealed = 0

    var targetText: String { String(target) }
    var shown: String { String(target.prefix(revealed)) }
    var backlog: Int { target.count - revealed }

    mutating func update(_ text: String) {
        target = Array(text)
        revealed = min(revealed, target.count)
    }

    mutating func step() {
        if revealed < target.count { revealed += 1 }
    }

    /// 下一个字隔多久露出：积压越多越快。
    func stepInterval(finishing: Bool) -> TimeInterval {
        let window = finishing ? Self.finishingWindow : Self.listeningWindow
        return min(max(window / Double(max(backlog, 1)), Self.fastestStep), Self.slowestStep)
    }
}

// MARK: - 诊断

/// 诊断用的识别替身：`say` 报一段实时文字，`finish` 给出 `finalText`（没设时用最后一段实时文字）。
/// `holdsFinish` 时收尾要等 `releaseFinish()`，用来检查松开后、定稿前又按了键的情况。
final class KeyiDiagnosticFakeDictation: KeyiDictationEngine {
    private(set) var starts = 0
    private(set) var cancels = 0
    var finalText: String?
    var holdsFinish = false
    private var onText: ((String) -> Void)?
    private var onEngine: ((KeyiDictationEngineInfo) -> Void)?
    private var live = ""
    private var pendingFinish: (() -> Void)?

    func start(
        onText: @escaping (String) -> Void,
        onEngine: @escaping (KeyiDictationEngineInfo) -> Void,
        onFailure: @escaping (KeyiDictationFailure) -> Void
    ) {
        starts += 1
        live = ""
        finalText = nil
        self.onText = onText
        self.onEngine = onEngine
        onEngine(KeyiDictationEngineInfo(name: KeyiDictationEngineInfo.localName, isCloud: false))
    }

    /// 像云端出错改用本机那样报一次引擎（带提示）。
    func switchEngine(_ info: KeyiDictationEngineInfo) {
        onEngine?(info)
    }

    func say(_ text: String) {
        live = text
        onText?(text)
    }

    func finish(_ completion: @escaping (String) -> Void) {
        onText = nil
        let text = finalText ?? live
        let run = { completion(text) }
        if holdsFinish {
            pendingFinish = run
        } else {
            DispatchQueue.main.async(execute: run)
        }
    }

    func releaseFinish() {
        guard let run = pendingFinish else { return }
        pendingFinish = nil
        DispatchQueue.main.async(execute: run)
    }

    func cancel() {
        cancels += 1
        onText = nil
        onEngine = nil
        pendingFinish = nil
    }
}

/// `KEYIIME --diagnose-dictation-file <音频> <应含文字>`：用包里的 SenseVoice 转写一个文件
/// （替掉的只是麦克风），检查运行库加载、模型、整理文字这条路。
public enum KeyiDictationDiagnostics {
    public enum Outcome {
        case transcribed(String, seconds: TimeInterval)
        case failed(String)
    }

    private final class Box<Value> {
        var value: Value?
    }

    /// 在主线程调用。`seconds` 是这次识别（含第一次加载模型）用的时间。
    public static func transcribe(file: URL, timeout: TimeInterval = 60) -> Outcome {
        let samples: [Float]
        do {
            samples = try KeyiMicrophone.samples(fromFile: file)
        } catch {
            return .failed("audio file unreadable: \(error.localizedDescription)")
        }
        let started = Date()
        let result = Box<String?>()
        KeyiSenseVoice.shared.transcribe(samples) { text, _ in result.value = .some(text) }
        let deadline = started.addingTimeInterval(timeout)
        while result.value == nil, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        guard let value = result.value else { return .failed("timed out") }
        guard let text = value else { return .failed("SenseVoice did not load (library or model missing)") }
        return .transcribed(KeyiDictationText.normalized(text), seconds: Date().timeIntervalSince(started))
    }
}
