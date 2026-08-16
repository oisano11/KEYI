import Carbon
import Foundation
import OSLog

@MainActor
final class GlobalHotKey {
    private let logger = Logger(
        subsystem: "com.keyi.input-translator",
        category: "HotKey"
    )
    enum Error: LocalizedError {
        case handlerRegistrationFailed(OSStatus)
        case hotKeyRegistrationFailed(OSStatus, String)

        var errorDescription: String? {
            switch self {
            case let .handlerRegistrationFailed(status):
                "快捷键监听初始化失败（\(status)）"
            case let .hotKeyRegistrationFailed(status, displayName):
                "快捷键 \(displayName) 无法注册，可能已被占用（\(status)）"
            }
        }
    }

    private var eventHandler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var action: (() -> Void)?
    private let identifier: EventHotKeyID

    private static var nextIdentifierID: UInt32 = 0

    init() {
        Self.nextIdentifierID &+= 1
        identifier = EventHotKeyID(
            signature: 0x48414E59,
            id: Self.nextIdentifierID
        )
    }

    func register(
        configuration: HotKeyConfiguration,
        action: @escaping () -> Void
    ) throws {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<GlobalHotKey>
                    .fromOpaque(context)
                    .takeUnretainedValue()
                var incomingIdentifier = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &incomingIdentifier
                )
                guard parameterStatus == noErr,
                      incomingIdentifier.signature == manager.identifier.signature,
                      incomingIdentifier.id == manager.identifier.id else {
                    return OSStatus(eventNotHandledErr)
                }
                MainActor.assumeIsolated {
                    manager.logger.info("Global hot key pressed")
                    manager.action?()
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw Error.handlerRegistrationFailed(handlerStatus)
        }

        let hotKeyStatus = RegisterEventHotKey(
            configuration.keyCode,
            configuration.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive),
            &hotKey
        )
        guard hotKeyStatus == noErr else {
            unregister()
            throw Error.hotKeyRegistrationFailed(
                hotKeyStatus,
                configuration.displayName
            )
        }
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }
}
