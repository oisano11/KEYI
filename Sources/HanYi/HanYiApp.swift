import SwiftUI

@main
struct HanYiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: .shared)
        } label: {
            StatusItemLabel(model: .shared)
        }
    }
}
