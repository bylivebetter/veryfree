//
//  OverlayView.swift
//  Speakin
//
//  The round button. Layer-backed so state changes and the level meter animate cheaply.
//

import AppKit

final class OverlayView: NSView {
    enum Appearance: Equatable {
        case starting(progress: Double?)
        case idle
        case recording
        case transcribing
        case success(symbol: String)
        case warning
        case failed
    }

    static let windowSize = NSSize(width: 64, height: 64)
    private static let diameter: CGFloat = 44

    var onClick: (() -> Void)?
    var onMove: ((NSPoint) -> Void)?
    var onContextMenu: ((NSEvent) -> Void)?

    private let haloLayer = CALayer()
    private let circleLayer = CALayer()
    private let spinnerLayer = CAShapeLayer()
    private let glyphLayer = CALayer()

    private var currentAppearance: Appearance = .starting(progress: nil)
    private var smoothedLevel: CGFloat = 0
    private var dragStartMouse: NSPoint?
    private var dragStartOrigin: NSPoint?
    private var didDrag = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
        apply(.starting(progress: nil))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func buildLayers() {
        let d = Self.diameter
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let circleFrame = CGRect(x: center.x - d / 2, y: center.y - d / 2, width: d, height: d)

        haloLayer.frame = circleFrame
        haloLayer.cornerRadius = d / 2
        haloLayer.opacity = 0
        layer?.addSublayer(haloLayer)

        circleLayer.frame = circleFrame
        circleLayer.cornerRadius = d / 2
        circleLayer.shadowColor = NSColor.black.cgColor
        circleLayer.shadowOpacity = 0.35
        circleLayer.shadowRadius = 6
        circleLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(circleLayer)

        let inset: CGFloat = 4
        spinnerLayer.frame = circleFrame.insetBy(dx: inset, dy: inset)
        spinnerLayer.path = CGPath(ellipseIn: spinnerLayer.bounds, transform: nil)
        spinnerLayer.fillColor = nil
        spinnerLayer.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        spinnerLayer.lineWidth = 2.5
        spinnerLayer.lineCap = .round
        spinnerLayer.strokeEnd = 0
        layer?.addSublayer(spinnerLayer)

        glyphLayer.frame = CGRect(x: center.x - 11, y: center.y - 11, width: 22, height: 22)
        glyphLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(glyphLayer)
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for l in [haloLayer, circleLayer, spinnerLayer, glyphLayer] { l.contentsScale = scale }
    }

    // MARK: - State

    func apply(_ new: Appearance) {
        guard new != currentAppearance || glyphLayer.contents == nil else { return }
        currentAppearance = new

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.18)
        switch new {
        case .starting(let progress):
            circleLayer.backgroundColor = NSColor(white: 0.35, alpha: 0.92).cgColor
            setGlyph("arrow.down.circle")
            setSpinning(false)
            spinnerLayer.strokeEnd = CGFloat(progress ?? 0)
            spinnerLayer.opacity = progress == nil ? 0 : 1
            setHalo(active: false)
        case .idle:
            circleLayer.backgroundColor = NSColor(white: 0.13, alpha: 0.88).cgColor
            setGlyph("mic.fill")
            setSpinning(false)
            spinnerLayer.opacity = 0
            setHalo(active: false)
        case .recording:
            circleLayer.backgroundColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).cgColor
            setGlyph("mic.fill")
            setSpinning(false)
            spinnerLayer.opacity = 0
            setHalo(active: true)
        case .transcribing:
            circleLayer.backgroundColor = NSColor(srgbRed: 0.04, green: 0.52, blue: 1.0, alpha: 1).cgColor
            setGlyph("waveform")
            spinnerLayer.strokeEnd = 0.28
            spinnerLayer.opacity = 1
            setSpinning(true)
            setHalo(active: false)
        case .success(let symbol):
            circleLayer.backgroundColor = NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1).cgColor
            setGlyph(symbol)
            setSpinning(false)
            spinnerLayer.opacity = 0
            setHalo(active: false)
        case .warning:
            circleLayer.backgroundColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).cgColor
            setGlyph("ear.trianglebadge.exclamationmark")
            setSpinning(false)
            spinnerLayer.opacity = 0
            setHalo(active: false)
        case .failed:
            circleLayer.backgroundColor = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).cgColor
            setGlyph("exclamationmark")
            setSpinning(false)
            spinnerLayer.opacity = 0
            setHalo(active: false)
        }
        CATransaction.commit()
    }

    /// Microphone level 0...1; drives the halo while recording.
    func apply(level: Float) {
        guard case .recording = currentAppearance else { return }
        let target = CGFloat(min(1, level * 4))          // speech RMS rarely exceeds 0.25
        smoothedLevel = target > smoothedLevel ? target : smoothedLevel * 0.75 + target * 0.25
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        let scale = 1 + smoothedLevel * 0.45
        haloLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        haloLayer.opacity = Float(0.25 + smoothedLevel * 0.35)
        CATransaction.commit()
    }

    private func setHalo(active: Bool) {
        haloLayer.backgroundColor = NSColor(srgbRed: 1.0, green: 0.23, blue: 0.19, alpha: 1).cgColor
        if !active {
            haloLayer.opacity = 0
            haloLayer.transform = CATransform3DIdentity
            smoothedLevel = 0
        } else {
            haloLayer.opacity = 0.25
        }
    }

    private func setSpinning(_ spinning: Bool) {
        let key = "speakin.spin"
        if spinning {
            guard spinnerLayer.animation(forKey: key) == nil else { return }
            let anim = CABasicAnimation(keyPath: "transform.rotation.z")
            anim.fromValue = 0
            anim.toValue = -2 * Double.pi
            anim.duration = 0.9
            anim.repeatCount = .infinity
            spinnerLayer.add(anim, forKey: key)
        } else {
            spinnerLayer.removeAnimation(forKey: key)
        }
    }

    private func setGlyph(_ symbolName: String) {
        let config = NSImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        guard let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = symbol.size
        let tinted = NSImage(size: size, flipped: false) { rect in
            symbol.draw(in: rect)
            NSColor.white.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        glyphLayer.contents = tinted
    }

    // MARK: - Mouse: click toggles, drag moves, right-click shows the menu

    override func mouseDown(with event: NSEvent) {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStartMouse, let origin = dragStartOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - start.x
        let dy = now.y - start.y
        if !didDrag, hypot(dx, dy) < 4 { return }
        didDrag = true
        window.setFrameOrigin(NSPoint(x: origin.x + dx, y: origin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragStartMouse = nil; dragStartOrigin = nil }
        if didDrag {
            if let origin = window?.frame.origin { onMove?(origin) }
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onContextMenu?(event)
    }
}
