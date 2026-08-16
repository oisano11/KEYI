import SwiftUI

public struct KEYIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    public init() {}

    public var body: some Scene {
        MenuBarExtra {
            MenuBarContent(model: .shared)
        } label: {
            StatusItemLabel(model: .shared)
        }
    }
}
