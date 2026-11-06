import AppKit
import Carbon.HIToolbox
import OSLog

/// 「自动翻译」开关的快捷键：在 KEYI 拼音的输入框里按 ⌃⌥T 切换，无需打开输入法菜单。
///
/// 为什么用 Carbon 全局热键而不是 IMK 事件：IME 只接收 `recognizedEvents` 里的按键，
/// 而 ⌃/⌥ 组合被 `shouldPassThrough` 让给宿主应用（否则会吞掉常用快捷键）。
///
/// 全局热键会让所有应用都收不到 ⌃⌥T，而输入法进程在切到其他输入法后仍然常驻。因此只在
/// 有 KEYI 输入会话处于激活状态时注册，没有时注销，把这个组合键还给其他应用。
///
/// 判断依据是 IMK 的 activateServer / deactivateServer，而不是查询系统“当前输入源”：
/// 10-04 实测输入法进程查到的当前输入源会与用户正在打字的应用不一致，切回 KEYI 拼音后
/// 快捷键没有重新注册。IMK 的激活回调直接对应用户正在使用 KEYI 的那个输入框。
final class KeyiHotKeyManager {
    static let shared = KeyiHotKeyManager()

    /// 切换后广播，所有存活的输入会话据此同步控制器状态。
    static let didToggleNotification = Notification.Name(
        "com.keyi.inputmethod.keyi.automaticTranslationDidToggle"
    )
    /// 偏好键与菜单项共用，保证菜单勾选状态与热键一致。
    static let preferenceKey = "KEYIAutomaticTranslationEnabled"

    private static let logger = Logger(
        subsystem: "com.keyi.inputmethod.keyi",
        category: "HotKey"
    )

    /// ⌃⌥T：与输入法自身或常见的 `⌘`/`⌃` 单键快捷键都不冲突。
    private static let keyCode = UInt32(kVK_ANSI_T)
    private static let modifiers = UInt32(controlKey | optionKey)
    /// 'KEYI' 四字符签名，避免与其他应用的 Carbon 热键 id 冲突。
    private static let signature: OSType = 0x4B45_5949
    /// 激活/停用回调会在切换时短暂抖动（同一毫秒内先激活再停用），稍等再判断。
    private static let settleDelay: TimeInterval = 0.3

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isTracking = false
    private var pendingUpdate: DispatchWorkItem?
    /// 当前处于激活状态的 KEYI 输入会话；弱引用，会话被释放时自动移除。
    private let activeSessions = NSHashTable<AnyObject>.weakObjects()

    private init() {}

    /// 启动时调用一次：安装热键事件处理，并开始跟踪输入会话的激活状态。
    func startTracking() {
        guard !isTracking else { return }
        isTracking = true
        installHandler()
        updateRegistration()
    }

    /// 某个 KEYI 输入会话被激活（用户在该输入框里使用 KEYI 拼音）。
    func sessionDidActivate(_ session: AnyObject) {
        activeSessions.add(session)
        scheduleRegistrationUpdate()
    }

    /// 某个 KEYI 输入会话被停用（换了输入框、应用或输入法）。
    func sessionDidDeactivate(_ session: AnyObject) {
        activeSessions.remove(session)
        scheduleRegistrationUpdate()
    }

    /// 当前是否开启（未设置时默认开启）。
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    /// 切换并广播，返回切换后的状态。
    @discardableResult
    static func toggle() -> Bool {
        let enabled = !isEnabled
        UserDefaults.standard.set(enabled, forKey: preferenceKey)
        NotificationCenter.default.post(
            name: didToggleNotification,
            object: nil,
            userInfo: ["enabled": enabled]
        )
        return enabled
    }

    private var hasActiveSession: Bool {
        !activeSessions.allObjects.isEmpty
    }

    private func scheduleRegistrationUpdate() {
        pendingUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.updateRegistration()
        }
        pendingUpdate = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func updateRegistration() {
        guard isTracking else { return }
        if hasActiveSession {
            register()
        } else {
            unregister()
        }
    }

    private func register() {
        guard hotKeyRef == nil else { return }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            Self.keyCode,
            Self.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            // 注册失败（例如被其他应用占用）时不影响输入法主体功能：菜单里仍可切换。
            Self.logger.error("hotkey registration failed status=\(status)")
            return
        }
        hotKeyRef = ref
        Self.logger.notice("automatic translation hotkey registered")
    }

    private func unregister() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
        Self.logger.notice("automatic translation hotkey released")
    }

    private func installHandler() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<KeyiHotKeyManager>
                .fromOpaque(userData).takeUnretainedValue()
            manager.handlePress()
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &spec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func handlePress() {
        // Carbon 的分类事件通常在主线程投递，但不做假设：统一切回主队列，
        // 保证偏好写入、通知广播与浮层展示都在同一线程上按序发生。
        DispatchQueue.main.async {
            // 兜底：已经没有激活的 KEYI 输入会话就不切换，并把快捷键还回去。
            guard self.hasActiveSession else {
                self.updateRegistration()
                return
            }
            let enabled = Self.toggle()
            Self.logger.notice("hotkey toggled automatic translation enabled=\(enabled)")
            MainActor.assumeIsolated {
                KeyiToastPanel.show(
                    text: enabled ? "自动翻译：开" : "自动翻译：关"
                )
            }
        }
    }
}
