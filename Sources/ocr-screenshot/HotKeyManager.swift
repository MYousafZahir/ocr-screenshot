import Carbon
import Foundation

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let onHotKey: @Sendable () -> Void

    init(keyCode: UInt32, modifiers: UInt32, onHotKey: @escaping @Sendable () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onHotKey = onHotKey
    }

    func register() {
        guard hotKeyRef == nil else { return }

        let hotKeyID = EventHotKeyID(signature: 0x4F435253, id: 1) // "OCRS"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard status == noErr else { return }

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, eventRef, userData in
            guard let eventRef, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let handler = manager.onHotKey
            DispatchQueue.main.async {
                handler()
            }
            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetEventDispatcherTarget(),
            callback,
            1,
            &eventSpec,
            UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            &eventHandlerRef
        )
        if handlerStatus != noErr {
            unregister()
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }

    deinit {
        unregister()
    }
}
