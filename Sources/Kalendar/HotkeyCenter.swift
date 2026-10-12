// The global hotkey that toggles the popover: ⌃⌥Space (§11), registered with Carbon.
//
// RegisterEventHotKey reports success even when another app already holds the same combination
// (found in Kapture), so a conflict shows up only as the shortcut doing nothing. Other calendar
// apps may already use ⌃⌥Space. A shortcut recorder in Settings comes with milestone 6.
import Carbon.HIToolbox
import KalendarCore

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?

    func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotkeyCenter.shared.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
                                         EventHotKeyID(signature: OSType(0x4B4C4E44), id: 1),   // 'KLND'
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.shell.error("hotkey register failed: \(status)") }
    }
}
