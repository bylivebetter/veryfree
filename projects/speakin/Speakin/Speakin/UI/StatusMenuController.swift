//
//  StatusMenuController.swift
//  Speakin
//
//  Menu bar item plus the menu it shares with the overlay's right-click.
//

import AppKit
import Combine

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let controller: AppController
    private let sessions: SessionController
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    var onShowHistory: (() -> Void)?
    var onShowVocabulary: (() -> Void)?
    var onShowSessions: (() -> Void)?

    init(controller: AppController, sessions: SessionController) {
        self.controller = controller
        self.sessions = sessions
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        sessions.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let name: String
        if sessions.phase.isRecording {
            name = "record.circle.fill"
        } else {
            switch controller.phase {
            case .recording: name = "record.circle"
            case .transcribing: name = "ellipsis.circle"
            case .failed: name = "exclamationmark.circle"
            default: name = "mic.circle"
            }
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Speakin")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = sessions.phase.isRecording ? sessions.statusLine : controller.statusLine
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let engineName = controller.engineOption.map { "\($0.displayName) · \($0.kind.displayName)" } ?? "Speech model not ready"
        menu.addItem(disabled("Speakin — \(engineName)"))
        menu.addItem(disabled(controller.statusLine))
        if let mic = AudioRecorder.currentInputDeviceName {
            menu.addItem(disabled("Microphone: \(mic)"))
        }
        menu.addItem(.separator())

        let toggleTitle = controller.phase.isRecording ? "Stop & Transcribe" : "Start Recording"
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        toggle.isEnabled = controller.phase != .transcribing
        toggle.toolTip = "Global hotkey: \(controller.hotkey.displayString)"
        menu.addItem(toggle)
        menu.addItem(.separator())

        addRecordingItems(to: menu)
        menu.addItem(.separator())

        let recent = controller.store.records.prefix(8)
        if recent.isEmpty {
            menu.addItem(disabled("No transcriptions yet"))
        } else {
            menu.addItem(disabled("Recent — click to copy"))
            for record in recent {
                let item = NSMenuItem(title: record.preview, action: #selector(copyRecord(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = record.id
                item.toolTip = record.text
                item.indentationLevel = 1
                if record.status != .completed {
                    item.image = NSImage(systemSymbolName: record.status == .failed ? "exclamationmark.triangle" : "clock",
                                         accessibilityDescription: record.status.rawValue)
                }
                menu.addItem(item)
            }
        }
        let history = NSMenuItem(title: "Show History…", action: #selector(showHistory), keyEquivalent: "h")
        history.target = self
        menu.addItem(history)
        let termCount = controller.vocabulary.terms.count
        let vocabulary = NSMenuItem(title: "Vocabulary… (\(termCount) name\(termCount == 1 ? "" : "s"))", action: #selector(showVocabulary), keyEquivalent: "")
        vocabulary.target = self
        vocabulary.toolTip = "Names Speakin knows: your projects, apps and corrections"
        menu.addItem(vocabulary)
        let pendingCount = controller.store.records.filter(\.needsTranscription).count
        if pendingCount > 0 {
            let retry = NSMenuItem(title: "Transcribe \(pendingCount) Pending Recording\(pendingCount == 1 ? "" : "s")",
                                   action: #selector(retryPending), keyEquivalent: "")
            retry.target = self
            menu.addItem(retry)
        }
        menu.addItem(.separator())

        menu.addItem(languageMenuItem())

        let paste = NSMenuItem(title: "Paste Automatically", action: #selector(toggleAutoPaste), keyEquivalent: "")
        paste.target = self
        paste.state = controller.settings.autoPaste ? .on : .off
        paste.toolTip = "Off: the text is only copied to the clipboard"
        menu.addItem(paste)

        let fillers = NSMenuItem(title: "Remove Filler Words (um, uh…)", action: #selector(toggleFillerWords), keyEquivalent: "")
        fillers.target = self
        fillers.state = controller.settings.removeFillerWords ? .on : .off
        fillers.toolTip = "English only. The verbatim text is kept in History."
        menu.addItem(fillers)

        let names = NSMenuItem(title: "Fix Names from Vocabulary", action: #selector(toggleVocabulary), keyEquivalent: "")
        names.target = self
        names.state = controller.settings.vocabularyEnabled ? .on : .off
        names.toolTip = "Rewrite misheard names (Nocaps, Knomo…) using the vocabulary"
        menu.addItem(names)

        let sounds = NSMenuItem(title: "Sounds", action: #selector(toggleSounds), keyEquivalent: "")
        sounds.target = self
        sounds.state = controller.settings.soundsEnabled ? .on : .off
        menu.addItem(sounds)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        login.state = controller.settings.launchAtLogin ? .on : .off
        menu.addItem(login)

        if !controller.accessibilityGranted {
            let ax = NSMenuItem(title: "Allow Pasting (Accessibility)…", action: #selector(grantAccessibility), keyEquivalent: "")
            ax.target = self
            ax.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(ax)
        }
        if !controller.microphoneGranted {
            let mic = NSMenuItem(title: "Allow Microphone…", action: #selector(openMicrophoneSettings), keyEquivalent: "")
            mic.target = self
            mic.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(mic)
        }

        let folder = NSMenuItem(title: "Open Data Folder", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Speakin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    /// Recording what the Mac is playing — a call, a video, anything — with your voice.
    private func addRecordingItems(to menu: NSMenu) {
        let isRecording = sessions.phase.isRecording
        let title: String
        switch sessions.phase {
        case .recording(let since): title = "Stop Recording (\(AppController.format(Date().timeIntervalSince(since))))"
        case .starting, .finishing: title = sessions.statusLine
        case .idle, .failed: title = "Record \(sessions.settings.sessionSource.displayName)"
        }
        let record = NSMenuItem(title: title, action: #selector(toggleSessionRecording), keyEquivalent: "")
        record.target = self
        record.isEnabled = !sessions.phase.isTransitioning
        record.image = NSImage(systemSymbolName: isRecording ? "stop.circle.fill" : "record.circle",
                               accessibilityDescription: nil)
        record.toolTip = "Global hotkey: \(Hotkey.session.displayString) — saves an .m4a you can open and keep"
        menu.addItem(record)

        if isRecording {
            let voice: String
            let symbol: String
            if sessions.microphone == .off {
                (voice, symbol) = ("Your voice: not recorded", "mic.slash")
            } else if let name = sessions.status.microphoneName {
                (voice, symbol) = sessions.status.microphoneSilent
                    ? ("Your voice: \(name) — no sound coming in", "mic.slash")
                    : ("Your voice: \(name)", "mic.fill")
            } else {
                (voice, symbol) = ("Your voice: no microphone found", "mic.slash")
            }
            let item = disabled(voice)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.indentationLevel = 1
            menu.addItem(item)
        }

        if sessions.silentSystemAudio {
            let warning = NSMenuItem(title: "No system audio — allow Audio Recording…", action: #selector(openAudioRecordingSettings), keyEquivalent: "")
            warning.target = self
            warning.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)
            menu.addItem(warning)
        }

        menu.addItem(recordingSourceMenuItem())
        menu.addItem(microphoneMenuItem())

        let transcribe = NSMenuItem(title: "Transcribe Recordings", action: #selector(toggleTranscribeSessions), keyEquivalent: "")
        transcribe.target = self
        transcribe.state = sessions.settings.transcribeSessions ? .on : .off
        transcribe.toolTip = "Save a .txt transcript beside each recording"
        menu.addItem(transcribe)

        if !sessions.transcribing.isEmpty {
            let count = sessions.transcribing.count
            menu.addItem(disabled("Transcribing \(count) recording\(count == 1 ? "" : "s")…"))
        }

        let count = sessions.store.sessions.count
        let list = NSMenuItem(title: count > 0 ? "Recordings… (\(count))" : "Recordings…", action: #selector(showSessions), keyEquivalent: "r")
        list.target = self
        menu.addItem(list)

        let folder = NSMenuItem(title: "Open Recordings Folder", action: #selector(openSessionsFolder), keyEquivalent: "")
        folder.target = self
        folder.toolTip = sessions.store.folderURL.path
        menu.addItem(folder)
    }

    private func recordingSourceMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Record From", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let all = NSMenuItem(title: "All Audio", action: #selector(selectSessionSource(_:)), keyEquivalent: "")
        all.target = self
        all.state = sessions.settings.sessionSource == .allAudio ? .on : .off
        submenu.addItem(all)
        submenu.addItem(.separator())

        var listed = Set<String>()
        for process in AudioProcessList.current() where !process.bundleID.isEmpty {
            guard listed.insert(process.bundleID).inserted else { continue }
            let entry = NSMenuItem(title: process.isPlaying ? "\(process.name) ●" : process.name,
                                   action: #selector(selectSessionSource(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [process.bundleID, process.name]
            entry.state = sessions.settings.sessionSource.bundleID == process.bundleID ? .on : .off
            submenu.addItem(entry)
        }
        // The app chosen earlier may not be running now; keep it selectable.
        if case .app(let bundleID, let name) = sessions.settings.sessionSource, !listed.contains(bundleID) {
            let entry = NSMenuItem(title: "\(name) (not running)", action: #selector(selectSessionSource(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [bundleID, name]
            entry.state = .on
            submenu.addItem(entry)
        }
        if listed.isEmpty { submenu.addItem(disabled("No other apps are using audio")) }
        item.submenu = submenu
        return item
    }

    /// Whose voice goes in: automatically the mic the call is using, one picked by hand, or none.
    private func microphoneMenuItem() -> NSMenuItem {
        let choice = sessions.microphone
        let item = NSMenuItem(title: "Your Voice", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let automatic = NSMenuItem(title: "Automatic — the Mic Your Call Uses", action: #selector(selectSessionMicrophone(_:)), keyEquivalent: "")
        automatic.target = self
        automatic.state = choice == .automatic ? .on : .off
        automatic.toolTip = "Records the microphone Zoom, Teams, Meet… are using — your headset when it is in — and the Mac's input otherwise"
        submenu.addItem(automatic)
        submenu.addItem(.separator())

        var listed = false
        for microphone in AudioDevices.microphones() {
            let entry = NSMenuItem(title: microphone.name, action: #selector(selectSessionMicrophone(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [microphone.uid, microphone.name]
            if case .device(let uid, _) = choice, uid == microphone.uid {
                entry.state = .on
                listed = true
            }
            submenu.addItem(entry)
        }
        // The microphone picked earlier may be unplugged now; keep it selectable.
        if case .device(let uid, let name) = choice, !listed {
            let entry = NSMenuItem(title: "\(name) (not connected — using Automatic)", action: #selector(selectSessionMicrophone(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = [uid, name]
            entry.state = .on
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())

        let off = NSMenuItem(title: "Don't Record My Voice", action: #selector(selectSessionMicrophone(_:)), keyEquivalent: "")
        off.target = self
        off.tag = 1
        off.state = choice == .off ? .on : .off
        submenu.addItem(off)

        item.submenu = submenu
        return item
    }

    private func languageMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let system = NSMenuItem(title: "System Default (\(Locale.current.localizedString(forIdentifier: Locale.current.identifier) ?? Locale.current.identifier))",
                                action: #selector(selectLocale(_:)), keyEquivalent: "")
        system.target = self
        system.representedObject = nil
        system.state = controller.settings.localeIdentifier == nil ? .on : .off
        submenu.addItem(system)
        submenu.addItem(.separator())
        if controller.availableLocales.isEmpty {
            submenu.addItem(disabled("Loading…"))
        }
        for option in controller.availableLocales {
            let title = option.kind == .speechTranscriber ? option.displayName : "\(option.displayName) (dictation engine)"
            let entry = NSMenuItem(title: title, action: #selector(selectLocale(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = option.id
            entry.state = controller.settings.localeIdentifier == option.locale.identifier ? .on : .off
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Actions

    @objc private func toggleRecording() { controller.toggle() }

    @objc private func copyRecord(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let record = controller.store.record(withID: id) else { return }
        Paster.copy(record.text)
    }

    @objc private func showHistory() { onShowHistory?() }

    @objc private func showVocabulary() { onShowVocabulary?() }

    @objc private func showSessions() { onShowSessions?() }

    @objc private func toggleSessionRecording() { sessions.toggle() }

    @objc private func selectSessionMicrophone(_ sender: NSMenuItem) {
        if let pair = sender.representedObject as? [String], pair.count == 2 {
            sessions.microphone = .device(uid: pair[0], name: pair[1])
        } else {
            sessions.microphone = sender.tag == 1 ? .off : .automatic
        }
    }

    @objc private func toggleTranscribeSessions() { sessions.settings.transcribeSessions.toggle() }

    @objc private func openSessionsFolder() { sessions.store.openFolder() }

    @objc private func openAudioRecordingSettings() { sessions.openAudioRecordingSettings() }

    @objc private func selectSessionSource(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2 else {
            sessions.source = .allAudio
            return
        }
        sessions.source = .app(bundleID: pair[0], name: pair[1])
    }

    @objc private func toggleVocabulary() { controller.settings.vocabularyEnabled.toggle() }

    @objc private func retryPending() { controller.recoverPendingRecordings() }

    @objc private func selectLocale(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            controller.selectLocale(nil)
            return
        }
        controller.selectLocale(controller.availableLocales.first { $0.id == id })
    }

    @objc private func toggleSounds() { controller.settings.soundsEnabled.toggle() }

    @objc private func toggleAutoPaste() { controller.settings.autoPaste.toggle() }

    @objc private func toggleFillerWords() { controller.settings.removeFillerWords.toggle() }

    @objc private func toggleLaunchAtLogin() { controller.settings.launchAtLogin.toggle() }

    @objc private func grantAccessibility() { controller.requestAccessibility() }

    @objc private func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(controller.store.rootURL)
    }
}
