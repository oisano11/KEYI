import AppKit
import Combine
import SwiftUI

/// macOS 翻译状态 HUD。只在翻译状态期间出现，不在待机时占用屏幕顶部。
@MainActor
final class TranslationIslandController: ObservableObject {
    @Published private(set) var hasAppeared = false

    private let panel: NSPanel
    private let model: AppModel
    private var stateObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var hideTask: Task<Void, Never>?
    private var currentState: AppModel.State = .ready

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 38),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        panel.contentView = NSHostingView(rootView: TranslationHUDView(model: model))

        stateObserver = model.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.currentState = state
                self?.render(state)
            }
        languageObserver = model.$interfaceLanguage
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                self.currentState = model.state
                self.render(model.state)
            }
    }

    private func render(_ state: AppModel.State) {
        hideTask?.cancel()
        hideTask = nil

        switch state {
        case .ready:
            dismiss()
        case .preparing, .translating:
            show()
        case .success:
            show()
            scheduleHide(after: .seconds(1.8))
        case .permissionRequired:
            show()
            scheduleHide(after: .seconds(5))
        case .failure:
            show()
            scheduleHide(after: .seconds(6))
        }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
            if self?.currentState == .success {
                self?.currentState = .ready
            }
        }
    }

    private func show() {
        let size = hudSize()
        guard let screen = NSScreen.main else { return }
        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let y = screen.visibleFrame.maxY - size.height - (menuBarHeight > 0 ? 6 : 8)
        panel.setFrame(NSRect(
            x: screen.frame.midX - size.width / 2,
            y: y,
            width: size.width,
            height: size.height
        ), display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        hasAppeared = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            panel.animator().alphaValue = 1
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.hasAppeared = true
        }
    }

    private func dismiss() {
        guard panel.isVisible else { return }
        hasAppeared = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.panel.orderOut(nil) }
        })
    }

    private func hudSize() -> NSSize {
        let text: String
        switch currentState {
        case .preparing: text = model.strings.statusPreparing
        case .translating: text = model.selectedProviderName
        case .success: text = model.strings.statusSuccess
        case .permissionRequired: text = model.strings.statusPermissionRequired
        case let .failure(message): text = message
        case .ready: text = model.strings.appName
        }
        let width = (text as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium)
        ]).width
        return NSSize(width: min(max(width + 58, 112), 300), height: 38)
    }
}

private struct TranslationHUDView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            switch model.state {
            case .preparing, .translating:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.72)
                    .frame(width: 18, height: 18)
                Text(model.state == .preparing
                     ? model.strings.statusPreparing
                     : model.selectedProviderName)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            case .success:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .frame(width: 18, height: 18)
                Text(model.strings.statusSuccess)
                    .lineLimit(1)
            case .permissionRequired:
                Image(systemName: "lock.fill")
                    .foregroundStyle(.yellow)
                    .frame(width: 18, height: 18)
                Text(model.strings.statusPermissionRequired)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .allowsTightening(true)
            case let .failure(message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .frame(width: 18, height: 18)
                Text(message)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)
                    .truncationMode(.tail)
            case .ready:
                EmptyView()
            }
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, 15)
        .frame(height: 38, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(.regularMaterial, in: Capsule())
        .contentShape(Capsule())
        .onTapGesture {
            if model.state == .permissionRequired || model.state.isFailure {
                model.openSettings(.translation)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: model.state)
    }
}
