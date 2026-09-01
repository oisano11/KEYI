import SwiftUI

public struct KEYIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: model)
        } label: {
            StatusItemLabel(model: model)
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button(model.strings.settings) {
                    model.openSettings(.translation)
                }
                .keyboardShortcut(",")
            }
        }
    }
}
