import Carbon
import Foundation

/// Registers a system-wide global hotkey (Cmd+Shift+J) using Carbon RegisterEventHotKey.
final class GlobalHotKeyManager {
    static let shared = GlobalHotKeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var onTrigger: (() -> Void)?

    private init() {}

    func registerCmdShiftJ(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let mgr = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    mgr.onTrigger?()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &handlerRef
        )

        let hotKeyID = EventHotKeyID(signature: OSType(0x5748494D), id: 1) // 'WHIM'
        // kVK_ANSI_J = 0x26
        RegisterEventHotKey(
            UInt32(kVK_ANSI_J),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
