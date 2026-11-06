import Foundation

/// Minimal preferences for the input method. Only the candidate page size is
/// configurable in this card; everything else stays at fixed, safe defaults.
enum KeyiPreferences {
    /// The live preference domain. Independent of the bundle identifier so the
    /// user's Rime data keeps its own isolated directory across bundle-ID
    /// changes, as the task card requires.
    static let domain = "com.keyi.input-method"

    private static let candidatePageSizeKey = "candidatePageSize"

    /// 每页 7 个（2026-11-05 用户选定，参照苹果拼音），数字键 1–7 选词。
    static let defaultCandidatePageSize = 7

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            candidatePageSizeKey: defaultCandidatePageSize,
        ])
    }

    /// Candidate page size, clamped to the range the engine and window can
    /// render reliably.
    static var candidatePageSize: Int {
        let value = UserDefaults.standard.integer(
            forKey: candidatePageSizeKey
        )
        return min(max(value, 3), 9)
    }

    /// Rime user data. Kept under the input method's own Application Support
    /// directory so it never collides with the KEYI translation assistant or
    /// the upstream Ni input method.
    static var rimeUserDataURL: URL {
        // Diagnostics run against the real input method use a throwaway
        // directory: a smoke test must never write into the user's live
        // dictionary. The real input method never sets this variable.
        if let override = ProcessInfo.processInfo.environment[
            "KEYI_IME_USER_DATA_DIR"
        ], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return applicationSupportURL.appendingPathComponent(
            "Rime",
            isDirectory: true
        )
    }

    static var applicationSupportURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(
                "Library/Application Support",
                isDirectory: true
            )
        return base.appendingPathComponent(domain, isDirectory: true)
    }

    /// The throwaway Rime directory diagnostics are pointed at, or nil when the
    /// default user location is in effect.
    static var diagnosticsUserDataOverride: String? {
        ProcessInfo.processInfo.environment["KEYI_IME_USER_DATA_DIR"]
    }
}
