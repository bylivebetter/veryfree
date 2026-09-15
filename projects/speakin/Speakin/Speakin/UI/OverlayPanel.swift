//
//  OverlayPanel.swift
//  Speakin
//
//  Borderless, non-activating floating panel: it never takes keyboard focus away from the app
//  you are dictating into, follows you across Spaces and full-screen apps, and remembers where
//  you dropped it.
//

import AppKit

final class OverlayPanel: NSPanel {
    let overlayView = OverlayView(frame: NSRect(origin: .zero, size: OverlayView.windowSize))

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: OverlayView.windowSize),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = overlayView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Places the panel at a saved origin if it is still on some screen, else bottom-right of the main screen.
    func place(savedOrigin: NSPoint?) {
        if let origin = savedOrigin, isVisible(origin: origin) {
            setFrameOrigin(origin)
            return
        }
        setFrameOrigin(defaultOrigin())
    }

    private func defaultOrigin() -> NSPoint {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return NSPoint(x: visible.maxX - frame.width - 20, y: visible.minY + 20)
    }

    private func isVisible(origin: NSPoint) -> Bool {
        let rect = NSRect(origin: origin, size: frame.size)
        return NSScreen.screens.contains { $0.visibleFrame.intersects(rect.insetBy(dx: 10, dy: 10)) }
    }
}
