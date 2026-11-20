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
        static let sessionsFolder = "sessionsFolder"
        static let sessionIncludesMicrophone = "sessionIncludesMicrophone"
        static let sessionMicrophoneUID = "sessionMicrophoneUID"
        static let sessionMicrophoneName = "sessionMicrophoneName"
        static let transcribeSessions = "transcribeSessions"
        static let sessionSourceBundleID = "sessionSourceBundleID"
        static let sessionSourceName = "sessionSourceName"
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

    // MARK: - Recording the Mac's audio

    /// Where recorded sessions are written. Visible in Finder on purpose.
    @Published var sessionsFolder: URL {
        didSet { defaults.set(sessionsFolder.path, forKey: Key.sessionsFolder) }
    }

    /// Mix the microphone in, so a call has both sides.
    @Published var sessionIncludesMicrophone: Bool {
        didSet { defaults.set(sessionIncludesMicrophone, forKey: Key.sessionIncludesMicrophone) }
    }

    /// Which microphone: automatic (the one the call is using) unless one was picked by hand.
    var sessionMicrophone: MicrophoneChoice {
        get {
            guard sessionIncludesMicrophone else { return .off }
            guard let uid = defaults.string(forKey: Key.sessionMicrophoneUID) else { return .automatic }
            return .device(uid: uid, name: defaults.string(forKey: Key.sessionMicrophoneName) ?? uid)
        }
        set {
            objectWillChange.send()
            switch newValue {
            case .off:
                sessionIncludesMicrophone = false
            case .automatic:
                defaults.removeObject(forKey: Key.sessionMicrophoneUID)
                defaults.removeObject(forKey: Key.sessionMicrophoneName)
                sessionIncludesMicrophone = true
            case .device(let uid, let name):
                defaults.set(uid, forKey: Key.sessionMicrophoneUID)
                defaults.set(name, forKey: Key.sessionMicrophoneName)
                sessionIncludesMicrophone = true
            }
        }
    }

    @Published var transcribeSessions: Bool {
        didSet { defaults.set(transcribeSessions, forKey: Key.transcribeSessions) }
    }

    /// All audio, or just one app.
    @Published var sessionSource: SystemAudioSource {
        didSet {
            switch sessionSource {
            case .allAudio:
                defaults.removeObject(forKey: Key.sessionSourceBundleID)
                defaults.removeObject(forKey: Key.sessionSourceName)
            case .app(let bundleID, let name):
                defaults.set(bundleID, forKey: Key.sessionSourceBundleID)
                defaults.set(name, forKey: Key.sessionSourceName)
            }
        }
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
        defaults.register(defaults: [Key.soundsEnabled: true, Key.autoPaste: true, Key.removeFillerWords: true, Key.vocabularyEnabled: true,
                                     Key.sessionIncludesMicrophone: true, Key.transcribeSessions: true])
        localeIdentifier = defaults.string(forKey: Key.localeIdentifier)
        soundsEnabled = defaults.bool(forKey: Key.soundsEnabled)
        autoPaste = defaults.bool(forKey: Key.autoPaste)
        removeFillerWords = defaults.bool(forKey: Key.removeFillerWords)
        vocabularyEnabled = defaults.bool(forKey: Key.vocabularyEnabled)
        sessionsFolder = defaults.string(forKey: Key.sessionsFolder).map { URL(fileURLWithPath: $0) } ?? SessionStore.defaultFolder()
        sessionIncludesMicrophone = defaults.bool(forKey: Key.sessionIncludesMicrophone)
        transcribeSessions = defaults.bool(forKey: Key.transcribeSessions)
        if let bundleID = defaults.string(forKey: Key.sessionSourceBundleID) {
            sessionSource = .app(bundleID: bundleID, name: defaults.string(forKey: Key.sessionSourceName) ?? bundleID)
        } else {
            sessionSource = .allAudio
        }
    }
}
