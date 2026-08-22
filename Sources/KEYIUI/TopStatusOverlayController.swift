import AppKit
import Combine

@MainActor
final class TopStatusOverlayController {
    private let panel: NSPanel
    private let container: NSVisualEffectView
    private let stack: NSStackView
    private let progressIndicator: NSProgressIndicator
    private let imageView: NSImageView
    private let label: NSTextField
    private var stateObserver: AnyCancellable?
    private var languageObserver: AnyCancellable?
    private var hideTask: Task<Void, Never>?

    init(model: AppModel) {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 46),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        container = NSVisualEffectView()
        stack = NSStackView()
        progressIndicator = NSProgressIndicator()
        imageView = NSImageView()
        label = NSTextField(labelWithString: "")

        configurePanel()
        configureContent()

        stateObserver = model.$state
            .removeDuplicates()
            .sink { [weak self] state in
                self?.render(state)
            }
        languageObserver = model.$interfaceLanguage
            .sink { [weak self, weak model] _ in
                guard let self, let model else { return }
                self.render(model.state)
            }
    }

    private func configurePanel() {
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]
    }

    private func configureContent() {
        container.material = .hudWindow
        container.blendingMode = .withinWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 15
        container.layer?.masksToBounds = true

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false

        imageView.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 15,
            weight: .semibold
        )
        imageView.imageScaling = .scaleProportionallyDown

        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.addArrangedSubview(progressIndicator)
        stack.addArrangedSubview(imageView)
        stack.addArrangedSubview(label)

        container.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 16),
            progressIndicator.heightAnchor.constraint(equalToConstant: 16),
            imageView.widthAnchor.constraint(equalToConstant: 18),
            imageView.heightAnchor.constraint(equalToConstant: 18)
        ])
        panel.contentView = container
    }

    private func render(_ state: AppModel.State) {
        hideTask?.cancel()
        hideTask = nil

        switch state {
        case .ready:
            hide()
        case .preparing:
            showProgress(text: "\(InterfaceStrings.current.statusPreparing)…")
        case .translating:
            showProgress(text: "\(InterfaceStrings.current.statusTranslating)…")
        case .success:
            showResult(
                text: InterfaceStrings.current.statusSuccess,
                symbolName: "checkmark.circle.fill",
                color: .systemGreen,
                hideAfter: .seconds(2)
            )
        case .permissionRequired:
            showResult(
                text: InterfaceStrings.current.statusPermissionRequired,
                symbolName: "lock.fill",
                color: .systemYellow,
                hideAfter: .seconds(4)
            )
        case let .failure(message):
            showResult(
                text: message,
                symbolName: "exclamationmark.triangle.fill",
                color: .systemOrange,
                hideAfter: .seconds(5)
            )
        }
    }

    private func showProgress(text: String) {
        imageView.isHidden = true
        progressIndicator.isHidden = false
        progressIndicator.startAnimation(nil)
        show(text: text)
    }

    private func showResult(
        text: String,
        symbolName: String,
        color: NSColor,
        hideAfter delay: Duration
    ) {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isHidden = true
        imageView.isHidden = false
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        imageView.contentTintColor = color
        show(text: text)

        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func show(text: String) {
        label.stringValue = text
        label.sizeToFit()
        let width = min(max(label.fittingSize.width + 76, 176), 520)
        let size = NSSize(width: width, height: 46)
        panel.setContentSize(size)
        positionPanel(size: size)
        panel.orderFrontRegardless()
    }

    private func hide() {
        progressIndicator.stopAnimation(nil)
        panel.orderOut(nil)
    }

    private func positionPanel(size: NSSize) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.main
            ?? NSScreen.screens.first { $0.frame.contains(mouseLocation) }
            ?? NSScreen.screens.first
        guard let visibleFrame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.maxY - size.height - 10
        )
        panel.setFrameOrigin(origin)
    }
}
