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

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | shiftKey))

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
        case kVK_Space: "Space"
        default: "key\(keyCode)"
        }
    }
}

@MainActor
final class HotkeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x53504B4E // 'SPKN'

    var onPress: (() -> Void)?

    func register(_ hotkey: Hotkey) throws {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(GetEventDispatcherTarget(), hotkeyEventHandler, 1, &eventType, selfPointer, &handlerRef)
        guard installStatus == noErr else { throw HotkeyError.installFailed(installStatus) }

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, id, GetEventDispatcherTarget(), 0, &hotKeyRef)
        guard registerStatus == noErr else {
            unregister()
            throw HotkeyError.registerFailed(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func fire() {
        onPress?()
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
    guard let userData else { return noErr }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    MainActor.assumeIsolated {
        manager.fire()
    }
    return noErr
}
