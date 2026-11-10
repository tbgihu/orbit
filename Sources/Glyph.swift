import AppKit
import UniformTypeIdentifiers

/// Orbit's mark: a ring with a satellite and the orbit's content inside. Drawn as the menu bar badge (a template
/// image), in the window, and as every launcher's icon.
enum Glyph {
    /// Where the satellite rests, in degrees counter-clockwise from the right (upper right).
    static let restingAngle: CGFloat = 50

    /// The alpha of a starting mark and of the unfinished part of a progress ring, shared so the two always match.
    /// The finished part is drawn at full strength, like a running mark.
    static let dimmedAlpha: CGFloat = 0.35

    /// Shapes with a short text knocked out of them.
    enum Shape: String, CaseIterable, Decodable, Sendable {
        /// Two stacked landscape panels (a visualisation, a set of views).
        case cards
        /// One landscape panel (a page, a window, a preview).
        case card
        /// A capsule (a tag, a service, an API).
        case pill
        /// A filled circle (a status, a single thing).
        case disc
        /// A document page with a folded corner (files, backups, exports, downloads).
        case file

        /// Characters that stay legible at menu bar size.
        var limit: Int {
            switch self {
            case .cards, .file: 2
            case .card, .pill, .disc: 3
            }
        }
    }

    /// What sits inside the ring, from an orbit's `badge` (default: its id as text). In orbits.json: `"abc"`
    /// (1 to 4 characters of text), `{"symbol": "globe"}` (an SF Symbol) or `{"shape": "cards", "text": "L"}`.
    enum Content: Equatable, Sendable, Decodable {
        case text(String)
        case symbol(String)
        case shape(Shape, String)

        static let textLimit = 4

        /// A one-line form, for Info.plist (`OrbitMark`) and `orbit internal icon`.
        var key: String {
            switch self {
            case .text(let text): "text:\(text)"
            case .symbol(let name): "symbol:\(name)"
            case .shape(let shape, let text): "\(shape.rawValue):\(text)"
            }
        }

        init(key: String) {
            let (kind, value) = key.firstIndex(of: ":").map { (String(key[..<$0]), String(key[key.index(after: $0)...])) }
                ?? ("text", key)
            self = kind == "symbol" ? .symbol(value) : Shape(rawValue: kind).map { .shape($0, value) } ?? .text(value)
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                self = .text(text)
                return
            }
            struct Object: Decodable { let symbol: String?, shape: Shape?, text: String? }
            let object = try container.decode(Object.self)
            switch (object.symbol, object.shape) {
            case (let name?, nil): self = .symbol(name)
            case (nil, let shape?): self = .shape(shape, object.text ?? "")
            default:
                throw DecodingError.dataCorruptedError(in: container, debugDescription:
                    "a badge is text, {\"symbol\": \"…\"} or {\"shape\": \"…\", \"text\": \"…\"}")
            }
        }

        /// Why it can't be drawn well, or nil.
        var problem: String? {
            switch self {
            case .text(let text) where !(1...Self.textLimit).contains(text.count):
                "text badge \"\(text)\": use 1 to \(Self.textLimit) characters"
            case .symbol(let name) where NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil:
                "no SF Symbol named \"\(name)\" (the SF Symbols app lists them)"
            case .shape(let shape, let text) where text.count > shape.limit:
                "\(shape.rawValue) badge \"\(text)\": up to \(shape.limit) characters"
            default: nil
            }
        }
    }

    struct Badge: Equatable {
        let content: Content
        let label: String
        var dimmed = false
        /// A failed run: a "!" in the top-right corner instead of the satellite.
        var alert = false
        /// Seconds per turn of the satellite, or nil when still. A turning ring is left out of the strip for `ring`.
        var turn: TimeInterval?
        /// A task's progress, shown by filling the ring instead of turning it. Also drawn by `ring`.
        var progress: Progress?

        /// Whether its ring is drawn separately, by `ring`.
        var ringApart: Bool { turn != nil || progress != nil }

        /// The part the strip draws, which doesn't change with the turn speed or percentage.
        var inStrip: Badge {
            var badge = self
            (badge.turn, badge.progress) = (ringApart ? 0 : nil, nil)
            return badge
        }
    }

    static let side: CGFloat = 20, spacing: CGFloat = 4

    /// The frame of the badge at `index` in a strip.
    static func cell(_ index: Int) -> NSRect {
        NSRect(x: CGFloat(index) * (side + spacing), y: 0, width: side, height: side)
    }

    /// All running badges side by side, as one template image (the menu bar tints it for every appearance).
    static func strip(_ badges: [Badge]) -> NSImage {
        let width = CGFloat(badges.count) * side + CGFloat(max(badges.count - 1, 0)) * spacing
        let image = NSImage(size: NSSize(width: max(width, side), height: side), flipped: false) { _ in
            for (index, badge) in badges.enumerated() {
                orbit(badge.content, in: cell(index).insetBy(dx: 0.5, dy: 0.5), lineWidth: 1.3,
                      color: .black, alpha: badge.dimmed ? dimmedAlpha : 1, alert: badge.alert,
                      parts: badge.ringApart ? .content : .all)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = badges.map(\.label).joined(separator: ", ")
        return image
    }

    /// A badge's ring and satellite alone, at rest or showing `progress`, as a template image the size of a cell.
    static func ring(dimmed: Bool, progress: Progress? = nil) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            orbit(.text(""), in: cell(0).insetBy(dx: 0.5, dy: 0.5), lineWidth: 1.3,
                  color: .black, alpha: dimmed ? dimmedAlpha : 1, parts: .ring, progress: progress)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// The app icon at `pixels` square, on the macOS 26+ icon grid (824 pt body in a 1024 pt canvas).
    static func appIcon(_ content: Content, pixels: Int) -> CGImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let s = CGFloat(pixels) / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        NSGradient(starting: NSColor(white: 0.27, alpha: 1), ending: NSColor(white: 0.09, alpha: 1))?
            .draw(in: shape, angle: -90)
        NSColor(white: 1, alpha: 0.12).setStroke()                       // hairline rim, as system icons have
        shape.lineWidth = 4 * s
        shape.stroke()

        let face = NSRect(x: body.midX - 290 * s, y: body.midY - 290 * s, width: 580 * s, height: 580 * s)
        orbit(content, in: face, lineWidth: 30 * s, color: .white)
        return rep.cgImage
    }

    /// Writes an `.icns` with every size Finder, Spotlight and the Dock ask for.
    static func writeICNS(_ content: Content, to file: URL) throws {
        struct Failed: Error {}
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let icns = CGImageDestinationCreateWithURL(file as CFURL, UTType.icns.identifier as CFString,
                                                         sizes.count, nil) else { throw Failed() }
        for pixels in sizes {
            guard let image = appIcon(content, pixels: pixels) else { throw Failed() }
            CGImageDestinationAddImage(icns, image, nil)
        }
        guard CGImageDestinationFinalize(icns) else { throw Failed() }
    }

    // MARK: Drawing

    /// How far content reaches into the free radius, giving every kind of content the same clearance to the ring.
    private static let fill: CGFloat = 0.80

    /// Which parts of a mark to draw: all of it, only the ring and satellite, or only the content.
    private enum Parts { case all, ring, content }

    /// The ring with a gap around the resting satellite, and the content geometrically centred inside. Drawn in a
    /// transparency layer so knock-outs only cut the mark and `alpha` dims it as a whole.
    private static func orbit(_ content: Content, in rect: NSRect, lineWidth: CGFloat, color: NSColor,
                              alpha: CGFloat = 1, alert: Bool = false, parts: Parts = .all, progress: Progress? = nil) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setAlpha(alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        defer { context.endTransparencyLayer(); context.restoreGState() }

        color.set()
        let satelliteRadius = lineWidth * 1.45
        let center = NSPoint(x: rect.midX, y: rect.midY)
        let radius = rect.width / 2 - satelliteRadius                 // the satellite stays inside the bounds
        let gap = asin(min(1, (satelliteRadius + lineWidth * 0.9) / radius)) * 180 / .pi
        let angle = restingAngle

        if parts != .content, let progress {
            progressRing(progress, center: center, radius: radius, lineWidth: lineWidth, satellite: satelliteRadius, color: color)
        } else if parts != .content {
            let ring = NSBezierPath()
            ring.appendArc(withCenter: center, radius: radius, startAngle: angle + gap, endAngle: angle - gap + 360)
            ring.lineWidth = lineWidth
            ring.lineCapStyle = .round
            ring.stroke()

            let theta = angle * .pi / 180
            let dot = NSPoint(x: center.x + radius * cos(theta), y: center.y + radius * sin(theta))
            if !alert {
                NSBezierPath(ovalIn: NSRect(x: dot.x - satelliteRadius, y: dot.y - satelliteRadius,
                                            width: satelliteRadius * 2, height: satelliteRadius * 2)).fill()
            }
        }
        guard parts != .ring else { return }

        let inner = radius - lineWidth / 2                            // free radius inside the ring
        switch content {
        case .text(let text): letters(text, center: center, inner: inner, context: context)
        case .symbol(let name): symbol(name, center: center, inner: inner, color: color)
        case .shape(.cards, let text): cards(text, center: center, inner: inner, lineWidth: lineWidth, context: context)
        case .shape(.file, let text): file(text, center: center, inner: inner, lineWidth: lineWidth, context: context)
        case .shape(let shape, let text): solid(shape, text, center: center, inner: inner, context: context)
        }
        if alert { alertBadge(in: rect, lineWidth: lineWidth, context: context) }
    }

    /// A ring filling clockwise from 12 o'clock, the done part solid and the rest as light as a starting ring, with
    /// the satellite at the leading edge and the same clearance as at rest. A chain's steps are equal segments with
    /// slim gaps: finished ones solid, the running one filling, the rest light.
    private static func progressRing(_ progress: Progress, center: NSPoint, radius: CGFloat, lineWidth: CGFloat,
                                     satellite: CGFloat, color: NSColor) {
        let degrees = { (length: CGFloat) in asin(min(1, length / radius)) * 180 / .pi }
        let parts = max(progress.steps, 1), span = 360 / CGFloat(parts)
        // round caps reach half a line into the gap, so 1.5 lines leave half a line clear, the least that still
        // shows at 1x. A single step's gap is one line, so the done part's cap starts exactly at 12 o'clock.
        let gap = degrees(lineWidth * (parts > 1 ? 1.5 : 1)), clear = degrees(satellite + lineWidth * 0.9)
        let shortest = degrees(lineWidth)                       // shorter, with its round caps, it would be a dot
        let start = { (part: Int) in 90 - CGFloat(part) * span - gap / 2 }          // angles fall clockwise
        let step = min(progress.step, parts - 1)
        // The satellite's centre covers its step's whole span, from the middle of one gap to the middle of the next,
        // not only the drawn segment, so it sits at exactly 12 o'clock at 0 % and at 100 %. The clearance hides the
        // gap it sits in.
        let lead = 90 - (CGFloat(step) + CGFloat(progress.percent ?? 0) / 100) * span

        /// The arc from `from` down to `to`, minus the satellite's clearance.
        func arc(_ from: CGFloat, _ to: CGFloat, done: Bool) {
            var pieces = [(from, to)]
            for center in [lead - 360, lead, lead + 360] {
                pieces = pieces.flatMap { [($0.0, max($0.1, center + clear)), (min($0.0, center - clear), $0.1)] }
            }
            (done ? color : color.withAlphaComponent(dimmedAlpha)).setStroke()
            for (from, to) in pieces where from - to > shortest {
                let path = NSBezierPath()
                path.appendArc(withCenter: center, radius: radius, startAngle: from, endAngle: to, clockwise: true)
                path.lineWidth = lineWidth
                path.lineCapStyle = .round
                path.stroke()
            }
        }
        for part in 0..<parts {
            let (from, to) = (start(part), start(part + 1) + gap)
            if part == step {
                arc(from, lead, done: true)
                arc(lead, to, done: false)
            } else {
                arc(from, to, done: part < step)
            }
        }
        let theta = lead * .pi / 180
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x + radius * cos(theta) - satellite, y: center.y + radius * sin(theta) - satellite,
                                    width: satellite * 2, height: satellite * 2)).fill()
    }

    /// A filled disc with "!" cut out of it in the top-right corner, in place of the satellite and set off by a
    /// cut-out ring like the badges on app icons. The orbit stays recognisable and the problem is hard to miss.
    private static func alertBadge(in rect: NSRect, lineWidth: CGFloat, context: CGContext) {
        let r = rect.width * 0.25
        let disc = NSRect(x: rect.maxX - 2 * r, y: rect.maxY - 2 * r, width: 2 * r, height: 2 * r)
        let halo = lineWidth * 0.9
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: disc.insetBy(dx: -halo, dy: -halo)).fill()
        context.setBlendMode(.normal)
        NSBezierPath(ovalIn: disc).fill()
        // The "!" as a stem and a dot rather than a font glyph: taller and heavier than any font's, so it stays
        // legible at menu bar size.
        let d = 2 * r, stem = d * 0.21, tall = d * 0.64, gap = d * 0.08
        let bottom = disc.midY - tall / 2
        context.setBlendMode(.clear)
        NSBezierPath(ovalIn: NSRect(x: disc.midX - stem / 2, y: bottom, width: stem, height: stem)).fill()
        NSBezierPath(roundedRect: NSRect(x: disc.midX - stem / 2, y: bottom + stem + gap, width: stem, height: tall - stem - gap),
                     xRadius: stem / 2, yRadius: stem / 2).fill()
        context.setBlendMode(.normal)
    }

    /// Letters sized so their ink box keeps the same clearance to the ring whatever the text, with the ink box
    /// (not the line box) centred on the ring.
    private static func letters(_ text: String, center: NSPoint, inner: CGFloat, context: CGContext) {
        guard !text.isEmpty else { return }
        let unit = inkBounds(text, size: 100)
        let size = min(100 * inner * 0.68 / hypot(unit.width / 2, unit.height / 2), inner * 1.15)
        draw(line(text, size: size), centredAt: center, context: context)
    }

    /// An SF Symbol, centred and scaled to reach as far as other content.
    private static func symbol(_ name: String, center: NSPoint, inner: CGFloat, color: NSColor) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 100, weight: .bold)
            .applying(.init(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        let scale = inner * 0.92 / hypot(size.width / 2, size.height / 2)   // the box carries some padding
        image.draw(in: NSRect(x: center.x - size.width * scale / 2, y: center.y - size.height * scale / 2,
                              width: size.width * scale, height: size.height * scale))
    }

    /// A filled front card with the text knocked out, and an outlined back card offset up and to the left behind a
    /// cut-out gap. The pair's bounding box is centred on the ring.
    private static func cards(_ text: String, center: NSPoint, inner: CGFloat, lineWidth: CGFloat,
                              context: CGContext) {
        // proportions in arbitrary units: a roughly 4:3 landscape card, the back one offset by about a quarter
        let width: CGFloat = 1.12, height: CGFloat = 0.82, corner: CGFloat = 0.17, dx: CGFloat = 0.34, dy: CGFloat = 0.30
        let k = inner * fill / reach(width + dx, height + dy, corner)

        let front = NSRect(x: center.x - (width + dx) * k / 2 + dx * k, y: center.y - (height + dy) * k / 2,
                           width: width * k, height: height * k)
        let back = front.offsetBy(dx: -dx * k, dy: dy * k)
        let stroke = lineWidth * 0.85, cut = lineWidth * 0.65, r = corner * k

        let outline = NSBezierPath(roundedRect: back.insetBy(dx: stroke / 2, dy: stroke / 2),
                                   xRadius: r - stroke / 2, yRadius: r - stroke / 2)
        outline.lineWidth = stroke
        outline.stroke()

        context.setBlendMode(.clear)
        NSBezierPath(roundedRect: front.insetBy(dx: -cut, dy: -cut), xRadius: r + cut, yRadius: r + cut).fill()
        context.setBlendMode(.normal)
        NSBezierPath(roundedRect: front, xRadius: r, yRadius: r).fill()
        knockOut(text, in: front, context: context)
    }

    /// One filled shape with the text knocked out, centred.
    private static func solid(_ shape: Shape, _ text: String, center: NSPoint, inner: CGFloat, context: CGContext) {
        let (width, height, corner): (CGFloat, CGFloat, CGFloat) = switch shape {
        case .card: (1.30, 0.92, 0.18)
        case .pill: (1.70, 0.86, 0.43)
        case .disc, .cards, .file: (1, 1, 0.5)
        }
        let k = inner * (shape == .disc ? 0.72 : fill) / reach(width, height, corner)   // a full disc reads heavier
        let rect = NSRect(x: center.x - width * k / 2, y: center.y - height * k / 2, width: width * k, height: height * k)
        NSBezierPath(roundedRect: rect, xRadius: corner * k, yRadius: corner * k).fill()
        knockOut(text, in: shape == .disc ? rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12) : rect,
                 context: context)
    }

    /// A filled portrait page with its top-right corner folded down (set off by a cut-out line) and the text cut
    /// out below the fold. Centred on its bounding box like the other shapes.
    private static func file(_ text: String, center: NSPoint, inner: CGFloat, lineWidth: CGFloat, context: CGContext) {
        let width: CGFloat = 0.82, height: CGFloat = 1.04, corner: CGFloat = 0.12, fold: CGFloat = 0.32
        let k = inner * fill / reach(width, height, corner)
        let page = NSRect(x: center.x - width * k / 2, y: center.y - height * k / 2, width: width * k, height: height * k)
        let r = corner * k, f = fold * k

        let outline = NSBezierPath()                                   // rounded corners, the folded one cut off
        outline.move(to: NSPoint(x: page.minX + r, y: page.minY))
        outline.appendArc(from: NSPoint(x: page.maxX, y: page.minY), to: NSPoint(x: page.maxX, y: page.maxY), radius: r)
        outline.line(to: NSPoint(x: page.maxX, y: page.maxY - f))
        outline.line(to: NSPoint(x: page.maxX - f, y: page.maxY))
        outline.appendArc(from: NSPoint(x: page.minX, y: page.maxY), to: NSPoint(x: page.minX, y: page.minY), radius: r)
        outline.appendArc(from: NSPoint(x: page.minX, y: page.minY), to: NSPoint(x: page.maxX, y: page.minY), radius: r)
        outline.close()
        outline.fill()

        let crease = NSBezierPath()                                    // the folded flap's two inner edges
        crease.move(to: NSPoint(x: page.maxX - f, y: page.maxY))
        crease.line(to: NSPoint(x: page.maxX - f, y: page.maxY - f))
        crease.line(to: NSPoint(x: page.maxX, y: page.maxY - f))
        crease.lineWidth = lineWidth * 0.7
        crease.lineJoinStyle = .round
        context.setBlendMode(.clear)
        crease.stroke()
        context.setBlendMode(.normal)

        knockOut(text, in: NSRect(x: page.minX, y: page.minY, width: page.width, height: page.height - f * 0.9)
                    .insetBy(dx: page.width * 0.08, dy: 0), context: context)
    }

    /// The distance from a rounded rectangle's centre to its farthest point (a corner arc's centre plus its radius).
    private static func reach(_ width: CGFloat, _ height: CGFloat, _ corner: CGFloat) -> CGFloat {
        hypot(width / 2 - corner, height / 2 - corner) + corner
    }

    /// Cuts text out of what is drawn, its ink box centred in `rect` and at most 60% of its height and 70% of its width.
    private static func knockOut(_ text: String, in rect: NSRect, context: CGContext) {
        guard !text.isEmpty else { return }
        let unit = inkBounds(text, size: 100)
        let size = 100 * min(rect.height * 0.60 / unit.height, rect.width * 0.70 / unit.width)
        context.setBlendMode(.clear)
        draw(line(text, size: size), centredAt: NSPoint(x: rect.midX, y: rect.midY), context: context)
        context.setBlendMode(.normal)
    }

    private static func draw(_ line: CTLine, centredAt point: NSPoint, context: CGContext) {
        let ink = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        context.saveGState()
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: point.x - ink.midX, y: point.y - ink.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private static func line(_ text: String, size: CGFloat) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: rounded(size, weight: .bold),
            .kern: -size * 0.03,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }

    private static func inkBounds(_ text: String, size: CGFloat) -> CGRect {
        CTLineGetBoundsWithOptions(line(text, size: size), .useGlyphPathBounds)
    }

    private static func rounded(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
    }
}
