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
    private let statusItem: NSStatusItem
    let menu = NSMenu()
    private var cancellables = Set<AnyCancellable>()
    var onShowHistory: (() -> Void)?
    var onShowVocabulary: (() -> Void)?

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()
        controller.$phase
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
    }

    private func updateIcon() {
        let name: String
        switch controller.phase {
        case .recording: name = "record.circle"
        case .transcribing: name = "ellipsis.circle"
        case .failed: name = "exclamationmark.circle"
        default: name = "mic.circle"
        }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Speakin")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = controller.statusLine
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
