import AppKit

extension Glyph.Badge {
    /// Seconds per revolution of the satellite: starting, and a task running.
    static let startingPeriod = 1.4, runningPeriod = 3.0

    /// An orbit's badge as the menu bar shows it: its run (`job`), else failed, else idle (its plain mark).
    /// A starting badge is dimmed, and its satellite circles fast unless animation is off. A running one circles
    /// slowly when its animation setting says so. A task that reports progress fills its ring instead.
    @MainActor init(_ spec: OrbitSpec, job: Job?, failed: Bool) {
        switch job {
        case let job? where job.state == .starting:                    // not up yet, dimmed whatever the animation
            self.init(content: spec.mark, label: spec.name, dimmed: true,
                      turn: spec.circlesWhileStarting ? Self.startingPeriod : nil)
        case let job?:
            if let progress = job.progress {
                self.init(content: spec.mark, label: spec.name, progress: progress)
            } else {
                self.init(content: spec.mark, label: spec.name, turn: spec.circlesWhileRunning ? Self.runningPeriod : nil)
            }
        case nil where failed: self.init(content: spec.mark, label: "\(spec.name) failed", alert: true)
        case nil: self.init(content: spec.mark, label: spec.name)
        }
    }

    /// As shown now: Reduce Motion stops the turning but not the progress.
    @MainActor var shown: Glyph.Badge {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return self }
        var badge = self
        badge.turn = nil
        return badge
    }
}

/// A badge's ring and satellite in a layer of its own, over the rest of the badge. It turns once every `turn`
/// seconds smoothly, in phase with the clock, so rings at the same speed turn in step wherever they are, or
/// fills to its progress. In the menu bar it is drawn by the status button's cell, for its tint; elsewhere in `tint`.
@MainActor
final class Ring: NSView {
    struct State: Equatable {
        var dimmed: Bool
        var turn: TimeInterval?
        var progress: Progress?
    }

    /// The colour to draw in, or nil to draw like the button it sits on.
    var tint: NSColor? { didSet { if tint != oldValue { needsDisplay = true } } }
    /// Rests while its window is fully hidden (occluded, minimised, on another Space), so it costs nothing there.
    var restsWhenHidden = false
    /// Its place in the status button, set by the menu bar.
    var offset: NSLayoutConstraint?

    private var shown: State?
    private var ring: NSImage?
    /// Holds the picture and turns. The view's own layer can't: AppKit moves its anchor point back to a corner.
    private let dial = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        dial.actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]    // nothing fades or slides
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }                              // matches the status button
    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }        // clicks go to what is below

    override func makeBackingLayer() -> CALayer {
        let layer = super.makeBackingLayer()
        layer.addSublayer(dial)
        return layer
    }

    func show(_ state: State) {
        guard state != shown else { return }
        shown = state
        ring = Glyph.ring(dimmed: state.dimmed, progress: state.progress)
        dial.removeAnimation(forKey: "turn")
        needsDisplay = true
        needsLayout = true
    }

    /// Draws the ring once into the dial, for the current appearance and at the screen's scale. Turning it
    /// redraws nothing.
    override func updateLayer() {
        let scale = window?.backingScaleFactor ?? 2
        let width = Int((bounds.width * scale).rounded()), height = Int((bounds.height * scale).rounded())
        guard let ring, width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            dial.contents = nil
            return
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)                           // flipped, like the view
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        if let tint {
            Glyph.tinted(ring, tint).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                          respectFlipped: true, hints: nil)
        } else if let button = superview as? NSButton {
            (button.cell as? NSButtonCell)?.drawImage(ring, withFrame: bounds, in: button)
        }
        NSGraphicsContext.restoreGraphicsState()
        dial.contentsScale = scale
        dial.contents = context.makeImage()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if restsWhenHidden, let window {
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        needsLayout = true
    }

    @objc private func occlusionChanged() { needsLayout = true; layoutSubtreeIfNeeded() }

    /// Keeps the dial over the view and turns it clockwise about its centre, in phase with the clock so a
    /// redraw or a rest never makes it jump. It turns continuously, worked out by the render server for each frame
    /// from the time alone, so a frame the system drops under load costs a sixtieth of a second of motion, not a
    /// whole step. At most 60 frames a second, which is smooth for a dial this size and lets a faster display idle.
    override func layout() {
        super.layout()
        if dial.bounds.size != bounds.size { needsDisplay = true }
        dial.bounds = CGRect(origin: .zero, size: bounds.size)
        dial.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let hidden = restsWhenHidden && window?.occlusionState.contains(.visible) != true
        guard let turn = shown?.turn, !hidden else {
            dial.removeAnimation(forKey: "turn")
            return
        }
        guard dial.animation(forKey: "turn") == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = 2 * Double.pi                     // clockwise: the view is flipped
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.duration = turn
        animation.repeatCount = .infinity
        animation.beginTime = dial.convertTime(CACurrentMediaTime(), from: nil)
            - Date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: turn)
        animation.isRemovedOnCompletion = false
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        dial.add(animation, forKey: "turn")
    }
}

/// One badge outside the menu bar, drawn as the status item draws it: the still part from `Glyph.strip` and a
/// Ring over it when the ring turns or fills, scaled to the view and tinted for its appearance. It follows
/// Reduce Motion and rests while its window is hidden.
@MainActor
final class BadgeView: NSView {
    private var badge: Glyph.Badge?
    private var tint = NSColor.labelColor
    private var drawn: Glyph.Badge?
    private var image: NSImage?
    private var ring: Ring?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }                              // like the status button, so rings turn alike
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func show(_ badge: Glyph.Badge, tint: NSColor) {
        guard badge != self.badge || tint != self.tint else { return }
        (self.badge, self.tint) = (badge, tint)
        render()
    }

    @objc private func displayOptionsChanged() { render() }

    private func render() {
        guard let badge = badge?.shown else { return }
        let still = badge.inStrip
        if still != drawn {
            drawn = still
            image = Glyph.strip([badge])
            needsDisplay = true
        }
        if badge.ringApart {
            let ring = ring ?? {
                let ring = Ring(frame: bounds)
                ring.autoresizingMask = [.width, .height]
                ring.restsWhenHidden = true
                addSubview(ring)
                self.ring = ring
                return ring
            }()
            ring.tint = tint
            ring.show(.init(dimmed: badge.dimmed, turn: badge.turn, progress: badge.progress))
        } else {
            ring?.removeFromSuperview()
            ring = nil
        }
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        ring?.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        Glyph.tinted(image, tint).draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1,
                                       respectFlipped: true, hints: nil)
    }
}

extension Glyph {
    /// A template image in `color`, resolved for the current appearance. Neither is cached, so both are drawn
    /// afresh at the size they are shown and stay crisp when scaled.
    static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        image.cacheMode = .never
        let tinted = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceIn)
            return true
        }
        tinted.cacheMode = .never
        return tinted
    }
}
