//
//  AppDelegate.swift
//  Speakin
//
//  Menu-bar app (LSUIElement): no Dock icon, one status item, one floating round overlay.
//

import AppKit
import Combine
import SwiftUI
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = AppController.shared
    private var overlay: OverlayPanel!
    private var statusMenu: StatusMenuController!
    private var historyWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusMenu = StatusMenuController(controller: controller)
        statusMenu.onShowHistory = { [weak self] in self?.showHistory() }

        overlay = OverlayPanel()
        overlay.place(savedOrigin: controller.settings.overlayOrigin)
        overlay.overlayView.onClick = { [weak self] in self?.controller.toggle() }
        overlay.overlayView.onMove = { [weak self] origin in self?.controller.settings.overlayOrigin = origin }
        overlay.overlayView.onContextMenu = { [weak self] event in
            guard let self else { return }
            self.statusMenu.rebuild(self.statusMenu.menu)
            NSMenu.popUpContextMenu(self.statusMenu.menu, with: event, for: self.overlay.overlayView)
        }
        overlay.orderFrontRegardless()

        bindOverlay()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.willTerminate()
    }

    /// speakin://toggle, speakin://start, speakin://stop, speakin://history — for Shortcuts, Raycast, Stream Deck…
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == "speakin" {
            Log.app.info("url received: \(url.absoluteString, privacy: .public)")
            switch (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased() {
            case "toggle": controller.toggle()
            case "start": controller.startIfIdle()
            case "stop": controller.stopIfRecording()
            case "history": showHistory()
            default: Log.app.error("unknown URL: \(url.absoluteString, privacy: .public)")
            }
        }
    }

    private func bindOverlay() {
        controller.$phase
            .combineLatest(controller.$modelProgress)
            .receive(on: RunLoop.main)
            .sink { [weak self] phase, progress in
                guard let self else { return }
                let appearance: OverlayView.Appearance
                switch phase {
                case .starting: appearance = .starting(progress: progress)
                case .idle: appearance = .idle
                case .recording: appearance = .recording
                case .transcribing: appearance = .transcribing
                case .pasted: appearance = .success(symbol: "checkmark")
                case .copied: appearance = .success(symbol: "doc.on.clipboard")
                case .heardNothing: appearance = .warning
                case .failed: appearance = .failed
                }
                self.overlay.overlayView.apply(appearance)
                self.overlay.overlayView.toolTip = self.controller.statusLine
            }
            .store(in: &cancellables)

        controller.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.overlay.overlayView.apply(level: level) }
            .store(in: &cancellables)
    }

    /// Never shown (LSUIElement), but it is what makes ⌘C / ⌘V / ⌘A / ⌘W / ⌘Q work in our windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Speakin", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }

    private func showHistory() {
        if historyWindow == nil {
            let root = HistoryView(store: controller.store, controller: controller)
            let window = NSWindow(contentViewController: NSHostingController(rootView: root))
            window.title = "Speakin History"
            window.setContentSize(NSSize(width: 900, height: 560))
            window.styleMask.insert([.titled, .closable, .resizable, .miniaturizable])
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SpeakinHistory")
            historyWindow = window
        }
        NSApp.activate()
        historyWindow?.makeKeyAndOrderFront(nil)
    }
}
