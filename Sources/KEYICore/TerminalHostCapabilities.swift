import Foundation

/// Explicit routing policy for desktop text capture in terminal hosts.
///
/// A terminal's accessibility value may be a screen buffer rather than an
/// editable draft. Dedicated terminal hosts are therefore admitted only when
/// the focused AX field positively exposes a writable value and selection
/// range. VS Code is mixed: it is admitted only for a positively identified
/// Monaco editor field, while xterm.js surfaces and unknown controls fail
/// closed. This registry does not infer a draft from visible terminal text.
public enum TerminalHostCapabilities {
    public enum Host: String, CaseIterable, Sendable {
        case macOSTerminal
        case iTerm2
        case ghostty
        case warp
        case visualStudioCode
        case wezTerm
        case kitty
        case alacritty
    }

    public enum Route: Equatable, Sendable {
        /// The focused control belongs to an unregistered, ordinary app.
        case ordinary
        /// A dedicated terminal exposes a writable AX value and range.
        case editableTerminalDraft
        /// A positively marked, writable Monaco editor field in VS Code.
        case editableVSCodeEditor
        /// The target is known to be a terminal screen/helper, not a draft.
        case rejectTerminalScreen
        /// VS Code's focused control does not have enough structure evidence.
        case rejectUnclassifiedHybridTarget

        public var mayReadAXValue: Bool {
            switch self {
            case .ordinary, .editableTerminalDraft, .editableVSCodeEditor:
                true
            case .rejectTerminalScreen, .rejectUnclassifiedHybridTarget:
                false
            }
        }

        public var requiresTerminalObservation: Bool {
            self == .editableTerminalDraft
        }
    }

    private static let bundleIdentifiers: [String: Host] = [
        "com.apple.Terminal": .macOSTerminal,
        "com.googlecode.iterm2": .iTerm2,
        "com.mitchellh.ghostty": .ghostty,
        "dev.warp.Warp-Stable": .warp,
        "dev.warp.Warp-Preview": .warp,
        "com.microsoft.VSCode": .visualStudioCode,
        "com.microsoft.VSCodeInsiders": .visualStudioCode,
        "com.visualstudio.code.oss": .visualStudioCode,
        "org.wezfurlong.wezterm": .wezTerm,
        "com.github.wez.wezterm": .wezTerm,
        "net.kovidgoyal.kitty": .kitty,
        "org.alacritty": .alacritty
    ]

    private static let textInputRoles: Set<String> = [
        "AXTextField", "AXTextArea"
    ]
    private static let xtermHelperMarker = "xterm-helper-textarea"

    public static func host(for bundleIdentifier: String?) -> Host? {
        guard let bundleIdentifier else { return nil }
        return bundleIdentifiers[bundleIdentifier]
    }

    public static func isDedicatedTerminal(_ bundleIdentifier: String?) -> Bool {
        guard let host = host(for: bundleIdentifier) else { return false }
        return host != .visualStudioCode
    }

    /// Registered terminal and hybrid hosts must never fall through to the
    /// selection-copy / keyboard capture fallback.
    public static func allowsKeyboardFallback(bundleIdentifier: String?) -> Bool {
        host(for: bundleIdentifier) == nil
    }

    public static func route(
        bundleIdentifier: String?,
        role: String?,
        subrole: String? = nil,
        identifiers: Set<String> = [],
        domClassNames: Set<String> = [],
        isInWebArea: Bool = false,
        valueIsSettable: Bool,
        selectedRangeIsSettable: Bool
    ) -> Route {
        guard let host = host(for: bundleIdentifier) else { return .ordinary }
        guard subrole != "AXSecureTextField" else {
            return host == .visualStudioCode
                ? .rejectUnclassifiedHybridTarget
                : .rejectTerminalScreen
        }

        if host == .visualStudioCode {
            // xterm-helper-textarea is a CSS class in xterm.js, not a
            // guaranteed AXIdentifier. Match exact identifiers/classes only
            // when the host actually exposes that metadata; never fuzzy-match.
            let isXtermHelper = identifiers.contains(xtermHelperMarker)
                || domClassNames.contains(xtermHelperMarker)
                || domClassNames.contains("xterm")
            if isXtermHelper {
                return .rejectTerminalScreen
            }

            let isMonacoEditor = identifiers.contains("monaco-editor")
                || domClassNames.contains("monaco-editor")
            let isCompositionTextarea = domClassNames.contains("inputarea")
            guard isMonacoEditor,
                  !isCompositionTextarea,
                  isInWebArea,
                  let role,
                  textInputRoles.contains(role),
                  valueIsSettable,
                  selectedRangeIsSettable else {
                return .rejectUnclassifiedHybridTarget
            }
            return .editableVSCodeEditor
        }

        guard let role,
              textInputRoles.contains(role),
              valueIsSettable,
              selectedRangeIsSettable else {
            return .rejectTerminalScreen
        }
        return .editableTerminalDraft
    }
}
