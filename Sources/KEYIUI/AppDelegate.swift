import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "Lifecycle"
    )
    private var translationPanel: NSPanel?
    private var statusOverlay: TranslationIslandController?
    private var hotKey: GlobalHotKey?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("KEYI 可译 launched")
        NSApp.setActivationPolicy(.accessory)
        installTranslationHost()
        statusOverlay = TranslationIslandController(model: .shared)
        AppModel.shared.setHotKeyRegistrationHandler { [weak self] configuration in
            guard let self else { return }
            try self.replaceHotKey(with: configuration)
        }
        installHotKey()
        observeSystemResume()
        AppModel.shared.refreshAccessibilityStatus()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey?.unregister()
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
            contentRect: NSRect(x: -10_000, y: -10_000, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.alphaValue = 0.01
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.orderFrontRegardless()
        translationPanel = panel
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
