import Carbon.HIToolbox
import Foundation

/// System-wide keyboard shortcuts via Carbon hot keys. Unlike global event monitors, this
/// needs no Accessibility permission and never sees other keystrokes.
@MainActor
final class HotKeyCenter {
    struct Shortcut: Hashable, Codable, Identifiable {
        var keyCode: UInt32
        var modifiers: UInt32
        var display: String
        var id: String { display }

        static let optionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey), display: "⌥ Space")
        static let controlOptionSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey), display: "⌃⌥ Space")
        static let shiftCommandSpace = Shortcut(keyCode: UInt32(kVK_Space), modifiers: UInt32(shiftKey | cmdKey), display: "⇧⌘ Space")
        static let escape = Shortcut(keyCode: UInt32(kVK_Escape), modifiers: 0, display: "Esc")

        static let presets: [Shortcut] = [.optionSpace, .controlOptionSpace, .shiftCommandSpace]
    }

    private struct Registration {
        var reference: EventHotKeyRef?
        var onPress: () -> Void
        var onRelease: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var nextID: UInt32 = 1
    private var handlerInstalled = false
    private static let signature: OSType = 0x4153_4944 // 'ASID'

    @discardableResult
    func register(_ shortcut: Shortcut, onPress: @escaping () -> Void, onRelease: @escaping () -> Void = {}) -> UInt32? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var reference: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr else { return nil }
        registrations[id] = Registration(reference: reference, onPress: onPress, onRelease: onRelease)
        return id
    }

    func unregister(_ id: UInt32) {
        guard let registration = registrations.removeValue(forKey: id) else { return }
        if let reference = registration.reference { UnregisterEventHotKey(reference) }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var types = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            let kind = GetEventKind(event)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            DispatchQueue.main.async {
                MainActor.assumeIsolated { center.dispatch(id: id, pressed: kind == UInt32(kEventHotKeyPressed)) }
            }
            return noErr
        }, types.count, &types, context, nil)
    }

    private func dispatch(id: UInt32, pressed: Bool) {
        guard let registration = registrations[id] else { return }
        if pressed { registration.onPress() } else { registration.onRelease() }
    }
}
