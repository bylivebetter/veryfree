//
//  Paster.swift
//  Speakin
//
//  Puts text on the pasteboard and sends ⌘V to whatever app is frontmost. Sending keystrokes
//  needs the Accessibility permission; without it the text is still on the clipboard.
//

import AppKit
import ApplicationServices
import Carbon

@MainActor
enum Paster {
    static func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Copies, then pastes into the frontmost app. Returns false when ⌘V could not be sent.
    static func paste(_ text: String) async -> Bool {
        copy(text)
        guard isAccessibilityTrusted(prompt: false) else { return false }
        // The user may still be holding ⇧⌘ from the hotkey; ⌘⇧V means something else in many apps.
        await waitForModifiersReleased(timeout: 2)
        sendCommandV()
        return true
    }

    private static func waitForModifiersReleased(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        let watched: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]
        while Date() < deadline {
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(watched).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    private static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let key = CGKeyCode(kVK_ANSI_V)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
