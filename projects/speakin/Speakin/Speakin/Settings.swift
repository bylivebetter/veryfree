//
//  Settings.swift
//  Speakin
//

import AppKit
import Combine
import Foundation
import ServiceManagement

@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    private enum Key {
        static let localeIdentifier = "localeIdentifier"
        static let soundsEnabled = "soundsEnabled"
        static let autoPaste = "autoPaste"
        static let removeFillerWords = "removeFillerWords"
        static let vocabularyEnabled = "vocabularyEnabled"
        static let overlayOriginX = "overlayOriginX"
        static let overlayOriginY = "overlayOriginY"
    }

    /// nil means "follow the system language".
    @Published var localeIdentifier: String? {
        didSet { defaults.set(localeIdentifier, forKey: Key.localeIdentifier) }
    }

    @Published var soundsEnabled: Bool {
        didSet { defaults.set(soundsEnabled, forKey: Key.soundsEnabled) }
    }

    /// Off = leave the text on the clipboard only.
    @Published var autoPaste: Bool {
        didSet { defaults.set(autoPaste, forKey: Key.autoPaste) }
    }

    /// Strip "um", "uh", "erm", "hmm" (English only). The verbatim text is still kept in the record.
    @Published var removeFillerWords: Bool {
        didSet { defaults.set(removeFillerWords, forKey: Key.removeFillerWords) }
    }

    /// Fix misheard names using the vocabulary (project names, apps, learned corrections).
    @Published var vocabularyEnabled: Bool {
        didSet { defaults.set(vocabularyEnabled, forKey: Key.vocabularyEnabled) }
    }

    var overlayOrigin: CGPoint? {
        get {
            guard defaults.object(forKey: Key.overlayOriginX) != nil else { return nil }
            return CGPoint(x: defaults.double(forKey: Key.overlayOriginX), y: defaults.double(forKey: Key.overlayOriginY))
        }
        set {
            if let p = newValue {
                defaults.set(p.x, forKey: Key.overlayOriginX)
                defaults.set(p.y, forKey: Key.overlayOriginY)
            } else {
                defaults.removeObject(forKey: Key.overlayOriginX)
                defaults.removeObject(forKey: Key.overlayOriginY)
            }
        }
    }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Speakin: launch at login change failed: \(error)")
            }
            objectWillChange.send()
        }
    }

    private init() {
        defaults.register(defaults: [Key.soundsEnabled: true, Key.autoPaste: true, Key.removeFillerWords: true, Key.vocabularyEnabled: true])
        localeIdentifier = defaults.string(forKey: Key.localeIdentifier)
        soundsEnabled = defaults.bool(forKey: Key.soundsEnabled)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        removeFillerWords = defaults.bool(forKey: Key.removeFillerWords)
        vocabularyEnabled = defaults.bool(forKey: Key.vocabularyEnabled)
    }
}
