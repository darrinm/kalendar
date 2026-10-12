// The global hotkey that toggles the popover: ⌃⌥Space by default (§11), registered with Carbon and
// changed with the shortcut recorder in Settings › General.
//
// RegisterEventHotKey reports success even when another app already holds the same combination
// (found in Kapture), so a conflict shows up only as the shortcut doing nothing. Other calendar
// apps may already use ⌃⌥Space.
import AppKit
import Carbon.HIToolbox
import KalendarCore
import SwiftUI

@MainActor
final class HotkeyCenter {
    static let shared = HotkeyCenter()

    var handler: (() -> Void)?
    private var ref: EventHotKeyRef?
    private var handlerInstalled = false

    /// Registers `hotkey`, replacing the previous one.
    func register(_ hotkey: Preferences.Hotkey) {
        if !handlerInstalled {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotkeyCenter.shared.handler?() }
                return noErr
            }, 1, &spec, nil, nil)
            handlerInstalled = true
        }
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.modifiers,
                                         EventHotKeyID(signature: OSType(0x4B4C4E44), id: 1),   // 'KLND'
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { Log.shell.error("hotkey register failed: \(status)") }
    }

    /// While the recorder listens, the old shortcut must not fire.
    func suspend() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}

extension Preferences.Hotkey {
    /// "⌃⌥Space"
    var display: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Escape: return "⎋"
        case kVK_Delete: return "⌫"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default: break
        }
        // the character the key types on the current keyboard layout
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "#\(code)" }
        let layout = unsafeBitCast(data, to: CFData.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = CFDataGetBytePtr(layout).withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) {
            UCKeyTranslate($0, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        }
        return status == noErr && length > 0 ? String(utf16CodeUnits: chars, count: length).uppercased() : "#\(code)"
    }

    /// Carbon modifier flags from AppKit's.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        // a global shortcut needs ⌃, ⌥ or ⌘; ⇧ alone would take a character from every app
        guard mods & UInt32(controlKey | optionKey | cmdKey) != 0 else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }
}

/// Settings › General › Global shortcut: click, then press the new combination. Esc cancels.
struct ShortcutRecorder: View {
    @Bindable var prefs: Preferences
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? "Type shortcut…" : prefs.hotkey.display) { recording ? stop() : start() }
                .frame(minWidth: 120)
                .accessibilityLabel(recording ? "Recording shortcut" : "Global shortcut, \(prefs.hotkey.display)")
            if prefs.hotkey != .standard && !recording {
                Button("Reset") { prefs.hotkey = .standard }
            }
        }
        .onDisappear { if recording { stop() } }
        // the Settings window is kept when closed, so onDisappear alone does not end recording
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if recording { stop() }
        }
    }

    private func start() {
        recording = true
        HotkeyCenter.shared.suspend()
        // the Settings window; a key typed in any other window (the Mini Window, say) ends recording
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else {
                stop()
                return event
            }
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
            } else if let hotkey = Preferences.Hotkey(event: event) {
                prefs.hotkey = hotkey
                stop()
            } else {
                NSSound.beep()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotkeyCenter.shared.register(prefs.hotkey)
    }
}
