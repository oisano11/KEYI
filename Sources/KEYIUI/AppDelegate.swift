import AppKit
import Combine
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Lifecycle"
    )
    private var translationPanel: NSPanel?
    private var translationHostObservation: AnyCancellable?
    private var statusOverlay: TranslationIslandController?
    private var hotKey: GlobalHotKey?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var settingsPreviewObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("KEYI 可译 launched")
        NSApp.setActivationPolicy(.accessory)
        installTranslationHost()
        KEYITranslationServiceHost.shared.startIfNeeded()
        // 选中本地模型时启动就在后台加载，第一次翻译不用等模型从磁盘读入。
        AppModel.shared.startManagingLocalModelServer()
        statusOverlay = TranslationIslandController(model: .shared)
        AppModel.shared.setHotKeyRegistrationHandler { [weak self] configuration in
            guard let self else { return }
            try self.replaceHotKey(with: configuration)
        }
        installHotKey()
        observeSystemResume()
        observeSettingsPreview()
        AppModel.shared.refreshAccessibilityStatus()
        // 雾凇词表：每周查一次上游，有新版只提示，用户确认才装。
        DictionaryUpdateModel.shared.startScheduledChecks()
        // KEYI 拼音的输入法菜单「翻译设置…」在 KEYI 可译没运行时带这个参数启动它。
        // 后面可跟页名（statistics、advanced），直接落到那一页（核对设置界面时用）。
        if let index = CommandLine.arguments.firstIndex(of: "--open-settings") {
            switch CommandLine.arguments.dropFirst(index + 1).first {
            case "statistics": AppModel.shared.openSettings(.statistics)
            case "advanced": AppModel.shared.openSettings(.general)
            default: openSettingsForReopen()
            }
        }
    }

    /// 核对设置界面用：本机别的进程发分布式通知 `com.keyi.input-translator.settingsPreview`，
    /// object 为页名（translation、statistics、advanced）时设置窗口落到那一页、摆到最前但不激活，
    /// 不抢用户正在打字的输入框；为 close 时收起。只打开或收起设置窗口，不改任何设置。
    private func observeSettingsPreview() {
        settingsPreviewObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.keyi.input-translator.settingsPreview"),
            object: nil,
            queue: .main
        ) { note in
            let page = note.object as? String
            MainActor.assumeIsolated {
                let controller = SettingsWindowController.shared
                switch page {
                case "close":
                    controller.window?.orderOut(nil)
                    return
                case "statistics": AppModel.shared.settingsSection = .statistics
                case "advanced": AppModel.shared.settingsSection = .general
                default: AppModel.shared.settingsSection = .translation
                }
                controller.window?.title = AppModel.shared.strings.settingsTitle
                controller.window?.orderFrontRegardless()
            }
        }
    }

    /// 菜单栏图标可能被刘海或别的图标挡住；再次打开 KEYI（访达、启动台、Spotlight）时直接打开设置。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettingsForReopen()
        return false
    }

    private func openSettingsForReopen() {
        AppModel.shared.openSettings(
            AppModel.shared.showsLocalModelMigrationNotice ? .providers(.localModel) : .translation
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        KEYITranslationServiceHost.shared.stop()
        LocalModelServer.shared.stop()
        hotKey?.unregister()
        translationHostObservation = nil
        translationPanel?.orderOut(nil)
        statusOverlay = nil
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(center.removeObserver)
        workspaceObservers.removeAll()
    }

    private func installTranslationHost() {
        let hostingView = NSHostingView(
            rootView: TranslationHostView(model: .shared)
        )
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 100),
            styleMask: [.titled, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.title = AppModel.shared.strings.appName
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        translationPanel = panel
        // SwiftUI translationTask must have a live, on-screen host. The previous
        // 1px window at (-10000, -10000) could suspend rendering indefinitely.
        // Installed language pairs use the non-UI session path; show this panel
        // only for the fallback that can need Apple's resource confirmation UI.
        translationHostObservation = AppModel.shared.$systemTranslationHostRequestID
            .removeDuplicates()
            .sink { [weak self] requestID in
                guard let self, let panel = self.translationPanel else { return }
                guard let requestID else {
                    panel.orderOut(nil)
                    return
                }
                if let screen = NSScreen.screens.first(where: {
                    NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
                }) ?? NSScreen.main {
                    let visible = screen.visibleFrame
                    panel.setFrameOrigin(NSPoint(
                        x: visible.midX - panel.frame.width / 2,
                        y: visible.midY - panel.frame.height / 2
                    ))
                }
                panel.title = AppModel.shared.strings.appName
                // A nonactivating panel stays visible without taking the
                // keyboard focus away from the text that was just captured.
                panel.orderFrontRegardless()
                self.logger.notice("System translation host presented; request_id=\(requestID.uuidString, privacy: .public)")
            }
    }

    private func installHotKey() {
        do {
            try replaceHotKey(with: AppModel.shared.hotKeyConfiguration)
        } catch {
            logger.error("Global hot key registration failed: \(error.localizedDescription, privacy: .private)")
            AppModel.shared.showError(error.localizedDescription)
        }
    }

    private func observeSystemResume() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification
        ]
        workspaceObservers = names.map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.recoverAfterSystemResume()
                }
            }
        }
    }

    private func recoverAfterSystemResume() {
        AppModel.shared.recoverAfterSystemResume()
        hotKey?.unregister()
        hotKey = nil
        installHotKey()
        logger.info("Global hot key refreshed after system resume")
    }

    private func replaceHotKey(with configuration: HotKeyConfiguration) throws {
        let replacement = GlobalHotKey()
        try replacement.register(configuration: configuration) {
            Task { await AppModel.shared.triggerTranslation() }
        }

        let previous = hotKey
        hotKey = replacement
        previous?.unregister()
        logger.info("Global hot key registered: \(configuration.displayName, privacy: .public)")
    }
}
