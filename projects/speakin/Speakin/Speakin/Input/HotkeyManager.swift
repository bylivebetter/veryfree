//
//  HotkeyManager.swift
//  Speakin
//
//  System-wide hotkey through Carbon's RegisterEventHotKey: works from any app, needs no
//  Accessibility permission, and wins over the frontmost app's own shortcuts.
//

import AppKit
import Carbon

nonisolated struct Hotkey: Equatable, Sendable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    /// Dictation: speak, then press again to paste.
    static let dictation = Hotkey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | shiftKey))
    /// Record what the Mac is playing (a call, a video) to a file.
    static let session = Hotkey(keyCode: UInt32(kVK_ANSI_R), carbonModifiers: UInt32(controlKey | shiftKey))

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyName
    }

    private var keyName: String {
        switch Int(keyCode) {
        case kVK_ANSI_D: "D"
        case kVK_ANSI_R: "R"
        case kVK_Space: "Space"
        default: "key\(keyCode)"
        }
    }
}

@MainActor
final class HotkeyManager {
    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1
    private static let signature: OSType = 0x53504B4E // 'SPKN'

    /// Registers one system-wide hotkey. Several can be live at once.
    func register(_ hotkey: Hotkey, action: @escaping () -> Void) throws {
        try installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers,
                                         EventHotKeyID(signature: Self.signature, id: id),
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { throw HotkeyError.registerFailed(status) }
        hotKeyRefs[id] = ref
        actions[id] = action
    }

    private func installHandlerIfNeeded() throws {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetEventDispatcherTarget(), hotkeyEventHandler, 1, &eventType, selfPointer, &handlerRef)
        guard status == noErr else { throw HotkeyError.installFailed(status) }
    }

    func unregister() {
        for ref in hotKeyRefs.values { UnregisterEventHotKey(ref) }
        hotKeyRefs.removeAll()
        actions.removeAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    enum HotkeyError: LocalizedError {
        case installFailed(OSStatus)
        case registerFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .installFailed(let s): "Could not install the hotkey handler (\(s))."
            case .registerFailed(let s): "Could not register the hotkey (\(s)). Another app may already use it."
            }
        }
    }
}

/// Carbon calls this on the main thread.
nonisolated private func hotkeyEventHandler(_ handler: EventHandlerCallRef?,
                                            _ event: EventRef?,
                                            _ userData: UnsafeMutableRawPointer?) -> OSStatus {
    guard let userData, let event else { return noErr }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr else { return noErr }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.fire(id: hotKeyID.id)
    }
    return noErr
}
