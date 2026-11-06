import AppKit
import Carbon.HIToolbox
import InputMethodKit
import KeyiIMEBridge
import KeyiIMEDiagnostics
import KeyiIMEInputController
import KeyiIMEKit
import OSLog

private let logger = Logger(
    subsystem: "com.keyi.inputmethod.keyi",
    category: "Lifecycle"
)

private final class InputMethodApplicationDelegate: NSObject,
    NSApplicationDelegate
{
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            KeyiIMEKit.prepareCandidatePanel()
        }
        logger.notice("Input method will finish launching")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("Input method ready")
    }
}

// InputMethodKit resolves its controller from Info.plist by class name. Touch
// both halves of the bridge so the Objective-C controller and the Swift
// session stay linked before the server starts.
_ = KeyiInputControllerClass()
_ = InputSession.self

func reportFailure(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(EXIT_FAILURE)
}

// Registers the *installed* bundle with Text Input Sources. Runs as the final
// step of Scripts/install-ime.sh, from the shipped executable, so the registered
// location is the canonical one. It never enables or selects the input source;
// the user still adds it in System Settings.
if CommandLine.arguments.contains("--register-installed") {
    let bundleURL = Bundle.main.bundleURL.standardizedFileURL
    let installedRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Input Methods", isDirectory: true)
        .standardizedFileURL
    guard bundleURL.path.hasPrefix(installedRoot.path + "/") else {
        reportFailure(
            "--register-installed must run from the installed bundle at \(installedRoot.path)"
        )
    }
    let status = TISRegisterInputSource(bundleURL as CFURL)
    guard status == noErr else {
        reportFailure("TISRegisterInputSource failed with status \(status)")
    }
    // Text Input Sources needs a moment before the new source can be listed,
    // and the parent input method must be visible before its mode is.
    let expected = [
        "com.keyi.inputmethod.keyi",
        "com.keyi.inputmethod.keyi.pinyin",
    ]
    var missing = Set(expected)
    let deadline = Date().addingTimeInterval(5)
    while !missing.isEmpty, Date() < deadline {
        if let sources = TISCreateInputSourceList(nil, true)?.takeRetainedValue()
            as? NSArray
        {
            for case let source as TISInputSource in sources {
                guard
                    let pointer = TISGetInputSourceProperty(
                        source,
                        kTISPropertyInputSourceID
                    )
                else { continue }
                let identifier = Unmanaged<CFString>
                    .fromOpaque(pointer).takeUnretainedValue() as String
                missing.remove(identifier)
            }
        }
        if !missing.isEmpty { Thread.sleep(forTimeInterval: 0.2) }
    }
    print("registered=\(bundleURL.path)")
    print("registered_status=\(status)")
    for identifier in expected {
        print("visible=\(identifier) \(missing.contains(identifier) ? "no" : "yes")")
    }
    guard missing.isEmpty else {
        reportFailure("registered but not enumerable: \(missing.sorted())")
    }
    print("enabled_or_selected_by_this_command=no")
    exit(EXIT_SUCCESS)
}

// KEYI 可译设置窗口读「学到的词」和导出时调用：从正在用的词库副本导出文本，打印词条数。
if let flag = CommandLine.arguments.firstIndex(of: "--export-user-dict") {
    guard CommandLine.arguments.indices.contains(flag + 1) else {
        reportFailure("--export-user-dict needs an output file")
    }
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let entries = KeyiUserDictionary.exportLiveDictionary(to: output)
    guard entries >= 0 else { reportFailure("user dictionary export failed") }
    print("entries=\(entries)")
    exit(EXIT_SUCCESS)
}

// KEYI 可译装新词表前调用：在一次性目录里试编译下载的雾凇词表，通过才装。
if let flag = CommandLine.arguments.firstIndex(of: "--verify-dictionary") {
    guard CommandLine.arguments.indices.contains(flag + 1) else {
        reportFailure("--verify-dictionary needs a directory")
    }
    let staged = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    guard KeyiDictionaryUpdates.verifyStagedTables(in: staged) else {
        reportFailure("staged dictionary did not build")
    }
    print("verified=1")
    exit(EXIT_SUCCESS)
}

// Diagnostics used by the build scripts; these never register an input source.
if CommandLine.arguments.contains("--diagnose-bundle") {
    let controllerClassName = Bundle.main.object(
        forInfoDictionaryKey: "InputMethodServerControllerClass"
    ) as? String
    guard
        let controllerClassName,
        let controllerClass = NSClassFromString(controllerClassName),
        controllerClass is IMKInputController.Type
    else {
        reportFailure("Invalid InputMethodServerControllerClass")
    }
    guard NSClassFromString("KeyiInputSession") != nil else {
        reportFailure("Invalid KeyiInputSession class")
    }
    print("controller=\(controllerClassName)")
    print("controller_resolved=true")
    print("session=KeyiInputSession")
    exit(EXIT_SUCCESS)
}

// Drives a real KeyiInputSession through the InputMethodKit callbacks with a
// mock text client. Never registers or selects an input source.
if CommandLine.arguments.contains("--diagnose-session") {
    runSessionDiagnostics()
}

// Automatic translation on, with a fake translator ("EN(<source>)") injected
// through the session's diagnostics seam. It only works when the script sets
// KEYI_IME_DIAGNOSTIC_FAKE_TRANSLATION=1. Real Rime, mock client.
if CommandLine.arguments.contains("--diagnose-session-translation") {
    runTranslationSessionDiagnostics()
}

guard
    let connectionName = Bundle.main.object(
        forInfoDictionaryKey: "InputMethodConnectionName"
    ) as? String,
    let bundleIdentifier = Bundle.main.bundleIdentifier
else {
    reportFailure("Missing input method bundle metadata")
}

guard let inputMethodServer = IMKServer(
    name: connectionName,
    bundleIdentifier: bundleIdentifier
) else {
    logger.fault(
        "Failed to create input method server connection=\(connectionName, privacy: .public) bundle=\(bundleIdentifier, privacy: .public)"
    )
    reportFailure("Unable to create the input method server")
}
logger.notice(
    "Input method server started connection=\(connectionName, privacy: .public) bundle=\(bundleIdentifier, privacy: .public)"
)

let application = NSApplication.shared
private let applicationDelegate = InputMethodApplicationDelegate()
application.delegate = applicationDelegate
application.setActivationPolicy(.accessory)
application.run()
withExtendedLifetime((inputMethodServer, applicationDelegate)) {}
