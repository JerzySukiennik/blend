// Blend app: layer-backed views updated every frame without SwiftUI (platters, the dual waveform strip, the live trackpad map).
import AppKit
import BlendEngine
import BlendKit
import QuartzCore
import SwiftUI

private func noActions(_ body: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    body()
    CATransaction.commit()
}

final class PlatterNSView: NSView, FrameDriven {
    let deck: Int
    private let disc = CALayer(), label = CALayer(), marker = CALayer(), spindle = CALayer(), shade = CALayer()
    private let ringBack = CAShapeLayer(), ring = CAShapeLayer()
    private var shownID: String?
    private var builtSize: CGFloat = 0
    private var lastAngle = Double.nan, lastProgress = -1.0, lastOpacity: Float = -1

    init(deck: Int) {
        self.deck = deck
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(ringBack)
        layer?.addSublayer(ring)
        layer?.addSublayer(shade)
        layer?.addSublayer(disc)
        disc.addSublayer(label)
        disc.addSublayer(marker)
        layer?.addSublayer(spindle)
        for l in [ringBack, ring] {
            l.fillColor = nil
            l.lineWidth = 2
            l.lineCap = .round
        }
        ringBack.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
        ring.strokeColor = NSColor(white: 0.96, alpha: 1).cgColor
        ring.strokeEnd = 0
        marker.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        spindle.backgroundColor = NSColor(white: 0.96, alpha: 1).cgColor
        label.masksToBounds = true
        label.contentsGravity = .resizeAspectFill
        label.backgroundColor = NSColor(white: 0.2, alpha: 1).cgColor
        shade.shadowColor = NSColor.black.cgColor
        shade.shadowOpacity = 0.5
        shade.shadowRadius = 22
        shade.shadowOffset = CGSize(width: 0, height: -12)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let side = min(bounds.width, bounds.height)
        guard side > 20, abs(side - builtSize) > 0.5 else { return }
        builtSize = side
        let scale = window?.backingScaleFactor ?? 2
        let inset: CGFloat = side * 0.045
        let d = side - inset * 2
        noActions {
            let box = CGRect(x: (bounds.width - d) / 2, y: (bounds.height - d) / 2, width: d, height: d)
            disc.bounds = CGRect(x: 0, y: 0, width: d, height: d)
            disc.position = CGPoint(x: box.midX, y: box.midY)
            disc.contents = Self.vinyl(diameter: d, scale: scale)
            disc.contentsScale = scale
            shade.frame = box
            shade.shadowPath = CGPath(ellipseIn: CGRect(origin: .zero, size: box.size), transform: nil)
            let ld = d * 0.46
            label.frame = CGRect(x: (d - ld) / 2, y: (d - ld) / 2, width: ld, height: ld)
            label.cornerRadius = ld / 2
            marker.frame = CGRect(x: d / 2 - 1.25, y: d * 0.77, width: 2.5, height: d * 0.2)
            marker.cornerRadius = 1.25
            let sd = d * 0.045
            spindle.frame = CGRect(x: box.midX - sd / 2, y: box.midY - sd / 2, width: sd, height: sd)
            spindle.cornerRadius = sd / 2
            let r = side / 2 - 1.5
            let path = CGMutablePath()
            path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: r, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
            for l in [ringBack, ring] {
                l.frame = bounds
                l.path = path
            }
        }
        lastAngle = .nan
    }

    static func vinyl(diameter d: CGFloat, scale: CGFloat) -> CGImage? {
        let px = Int(d * scale)
        guard px > 0, let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let c = CGPoint(x: CGFloat(px) / 2, y: CGFloat(px) / 2), r = CGFloat(px) / 2
        ctx.setFillColor(NSColor(white: 0.055, alpha: 1).cgColor)
        ctx.fillEllipse(in: CGRect(x: 0, y: 0, width: px, height: px))
        ctx.setLineWidth(max(1, scale * 0.5))
        var k = 0
        var rr = r * 0.5
        while rr < r * 0.97 {
            ctx.setStrokeColor(NSColor(white: k % 3 == 0 ? 0.13 : 0.09, alpha: 1).cgColor)
            ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
            rr += scale * 2.2
            k += 1
        }
        ctx.setStrokeColor(NSColor(white: 1, alpha: 0.07).cgColor)
        ctx.setLineWidth(scale)
        ctx.strokeEllipse(in: CGRect(x: scale / 2, y: scale / 2, width: CGFloat(px) - scale, height: CGFloat(px) - scale))
        return ctx.makeImage()
    }

    func frame(_ state: be_state, model: AppModel) {
        let d = state.deck(deck)
        let track = model.session.decks[deck].track
        if track?.info.id != shownID {
            shownID = track?.info.id
            noActions { label.contents = track.flatMap { CoverCache.cgImage(for: $0.info) } }
        }
        let opacity: Float = track == nil ? 0.28 : (d.playing != 0 ? 1 : 0.6)
        let angle = track == nil ? 0 : -(d.frame / 44100) * (100.0 / 180.0) * 2 * .pi
        let progress = track.map { min(1, max(0, d.frame / Double($0.analysis.frames))) } ?? 0
        guard angle != lastAngle || opacity != lastOpacity || abs(progress - lastProgress) > 0.0005 else { return }
        noActions {
            if angle != lastAngle { disc.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(angle.truncatingRemainder(dividingBy: 2 * .pi)))) }
            if opacity != lastOpacity {
                disc.opacity = opacity
                shade.opacity = track == nil ? 0 : 1
                ring.opacity = track == nil ? 0 : 1
            }
            if abs(progress - lastProgress) > 0.0005 { ring.strokeEnd = CGFloat(progress) }
        }
        lastAngle = angle
        lastOpacity = opacity
        lastProgress = progress
    }
}

struct PlatterView: NSViewRepresentable {
    let deck: Int
    let model: AppModel

    func makeNSView(context: Context) -> PlatterNSView {
        let v = PlatterNSView(deck: deck)
        model.register(v)
        return v
    }

    func updateNSView(_ view: PlatterNSView, context: Context) {}
}

final class WaveStripNSView: NSView, FrameDriven {
    static let ptPerBeat: CGFloat = 46
    static let tileBeats = 16

    private let lanes = [CALayer(), CALayer()]
    private let played = CALayer(), playhead = CALayer(), axis = CALayer()
    private var tiles: [[Int: CALayer]] = [[:], [:]]
    private var shown: [String?] = [nil, nil]
    private var lastBeat = [Double.nan, Double.nan]
    private var builtHeight: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.32).cgColor
        for l in lanes {
            l.anchorPoint = .zero
            layer?.addSublayer(l)
        }
        played.backgroundColor = NSColor(srgbRed: 0.07, green: 0.07, blue: 0.078, alpha: 0.62).cgColor
        axis.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
        playhead.backgroundColor = NSColor.white.cgColor
        playhead.shadowColor = NSColor.white.cgColor
        playhead.shadowOpacity = 0.5
        playhead.shadowRadius = 5
        playhead.shadowOffset = .zero
        layer?.addSublayer(played)
        layer?.addSublayer(axis)
        layer?.addSublayer(playhead)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        noActions {
            let h = bounds.height / 2
            lanes[0].frame = CGRect(x: 0, y: h, width: bounds.width, height: h)
            lanes[1].frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            played.frame = CGRect(x: 0, y: 0, width: bounds.width / 2, height: bounds.height)
            axis.frame = CGRect(x: 0, y: h - 0.5, width: bounds.width, height: 1)
            playhead.frame = CGRect(x: bounds.width / 2 - 1, y: 0, width: 2, height: bounds.height)
        }
        if abs(builtHeight - bounds.height) > 0.5 {
            builtHeight = bounds.height
            clear(0)
            clear(1)
        }
    }

    private func clear(_ deck: Int) {
        for (_, t) in tiles[deck] { t.removeFromSuperlayer() }
        tiles[deck] = [:]
        lastBeat[deck] = .nan
    }

    func frame(_ state: be_state, model: AppModel) {
        guard bounds.width > 10 else { return }
        for deck in 0..<2 {
            let track = model.session.decks[deck].track
            if track?.info.id != shown[deck] {
                shown[deck] = track?.info.id
                clear(deck)
            }
            guard let track else { continue }
            let beat = state.deck(deck).beat
            if beat == lastBeat[deck] { continue }
            lastBeat[deck] = beat
            let tileW = Self.ptPerBeat * CGFloat(Self.tileBeats)
            let half = bounds.width / 2
            let first = Int(floor((beat * Double(Self.ptPerBeat) - Double(half)) / Double(tileW)))
            let last = Int(floor((beat * Double(Self.ptPerBeat) + Double(half)) / Double(tileW)))
            noActions {
                for i in first...last where tiles[deck][i] == nil {
                    let t = CALayer()
                    t.anchorPoint = .zero
                    t.frame = CGRect(x: CGFloat(i) * tileW, y: 0, width: tileW, height: bounds.height / 2)
                    t.contentsScale = window?.backingScaleFactor ?? 2
                    t.contents = Self.tile(track, index: i, up: deck == 0, size: t.bounds.size, scale: t.contentsScale)
                    lanes[deck].addSublayer(t)
                    tiles[deck][i] = t
                }
                for (i, t) in tiles[deck] where i < first - 1 || i > last + 1 {
                    t.removeFromSuperlayer()
                    tiles[deck][i] = nil
                }
                lanes[deck].sublayerTransform = CATransform3DMakeTranslation(half - CGFloat(beat) * Self.ptPerBeat, 0, 0)
            }
        }
    }

    static func tile(_ track: LoadedTrack, index: Int, up: Bool, size: CGSize, scale: CGFloat) -> CGImage? {
        let w = Int(size.width * scale), h = Int(size.height * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        let a = track.analysis, st = track.structure
        let beat0 = Double(index * tileBeats)
        let fpb = track.fpb
        for b in 0..<tileBeats {
            let beat = Int(beat0) + b
            let rel = beat - st.barPhase
            guard rel % 4 == 0 else { continue }
            let bar = rel / 4
            let strong = st.isPhrase(bar, every: 8)
            ctx.setFillColor(NSColor.white.withAlphaComponent(strong ? 0.2 : 0.07).cgColor)
            ctx.fill(CGRect(x: CGFloat(b) * ptPerBeat, y: 0, width: strong ? 1 : 0.75, height: size.height))
            if st.drops.contains(bar) {
                ctx.setFillColor(NSColor.white.withAlphaComponent(0.9).cgColor)
                let y = up ? size.height - 5 : 0
                ctx.fill(CGRect(x: CGFloat(b) * ptPerBeat, y: y, width: 12, height: 5))
            }
        }
        let pitch: CGFloat = 3, bar: CGFloat = 2
        let count = Int(size.width / pitch)
        let points = track.wave.count / 4
        let unit = size.height * (track.stems == 4 ? 0.3 : 0.72)
        let order = up ? [3, 2, 1, 0] : [0, 1, 2, 3]
        for j in 0..<count {
            let x = CGFloat(j) * pitch
            let b0 = beat0 + Double(x / ptPerBeat), b1 = beat0 + Double((x + pitch) / ptPerBeat)
            let p0 = Int((a.firstBeatFrame + b0 * fpb) / 44100 * LoadedTrack.wavePoints)
            let p1 = max(p0 + 1, Int((a.firstBeatFrame + b1 * fpb) / 44100 * LoadedTrack.wavePoints))
            if p1 <= 0 || p0 >= points { continue }
            var v = [CGFloat](repeating: 0, count: 4)
            for p in max(0, p0)..<min(points, p1) {
                for s in 0..<4 { v[s] = max(v[s], CGFloat(track.wave[p * 4 + s]) / 255) }
            }
            var total = v.reduce(0, +) * unit
            let squeeze = total > size.height - 2 ? (size.height - 2) / total : 1
            total *= squeeze
            var y: CGFloat = up ? 0 : size.height
            for s in order {
                let hgt = v[s] * unit * squeeze
                if hgt < 0.3 { continue }
                ctx.setFillColor(Theme.stemsNS[track.stems == 4 ? s : 1].cgColor)
                if up {
                    ctx.fill(CGRect(x: x, y: y, width: bar, height: hgt))
                    y += hgt
                } else {
                    y -= hgt
                    ctx.fill(CGRect(x: x, y: y, width: bar, height: hgt))
                }
            }
        }
        return ctx.makeImage()
    }
}

struct WaveStripView: NSViewRepresentable {
    let model: AppModel

    func makeNSView(context: Context) -> WaveStripNSView {
        let v = WaveStripNSView(frame: .zero)
        model.register(v)
        return v
    }

    func updateNSView(_ view: WaveStripNSView, context: Context) {}
}

final class TrackpadMapNSView: NSView, FrameDriven {
    var highlight = 0 {
        didSet { needsDisplay = true }
    }
    private var dots: [CGPoint] = []

    override var isFlipped: Bool { false }

    func frame(_ state: be_state, model: AppModel) {
        if model.touches != dots {
            dots = model.touches
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let pad = CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil)
        ctx.addPath(pad)
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.05).cgColor)
        ctx.fillPath()
        ctx.addPath(pad)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.18).cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()

        let stripH = r.height * TrackpadZones.strip
        let cornerW = r.width * TrackpadZones.corner
        let lit = NSColor.white.withAlphaComponent(0.2).cgColor, quiet = NSColor.white.withAlphaComponent(0.07).cgColor
        func zone(_ rect: CGRect, _ on: Bool, radius: CGFloat = 10) {
            ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 3, dy: 3), cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(on ? lit : quiet)
            ctx.fillPath()
        }
        zone(CGRect(x: r.minX, y: r.minY, width: cornerW, height: stripH), highlight == 4)
        zone(CGRect(x: r.maxX - cornerW, y: r.minY, width: cornerW, height: stripH), highlight == 4)
        zone(CGRect(x: r.minX + cornerW, y: r.minY, width: r.width - cornerW * 2, height: stripH), highlight == 3)
        let discArea = CGRect(x: r.minX, y: r.minY + stripH, width: r.width, height: r.height - stripH)
        let d = min(discArea.width / 2, discArea.height) * 0.86
        for i in 0..<2 {
            let c = CGPoint(x: discArea.minX + discArea.width * (i == 0 ? 0.25 : 0.75), y: discArea.midY)
            let on = (highlight == 1 && i == 0) || highlight == 2
            ctx.setFillColor(on ? lit : quiet)
            ctx.fillEllipse(in: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d))
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
            ctx.fillEllipse(in: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6))
        }
        let labels: [(String, CGPoint)] = [
            ("DECK A", CGPoint(x: r.minX + r.width * 0.25, y: discArea.maxY - 20)),
            ("DECK B", CGPoint(x: r.minX + r.width * 0.75, y: discArea.maxY - 20)),
            ("CROSSFADE", CGPoint(x: r.midX, y: r.minY + stripH / 2 - 6)),
            ("▶", CGPoint(x: r.minX + cornerW / 2, y: r.minY + stripH / 2 - 6)),
            ("▶", CGPoint(x: r.maxX - cornerW / 2, y: r.minY + stripH / 2 - 6))
        ]
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor(white: 1, alpha: 0.5), .kern: 1.2]
        for (text, p) in labels {
            let s = NSAttributedString(string: text, attributes: attrs)
            let size = s.size()
            s.draw(at: CGPoint(x: p.x - size.width / 2, y: p.y))
        }
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.setShadow(offset: .zero, blur: 10, color: NSColor.white.withAlphaComponent(0.7).cgColor)
        for p in dots {
            let c = CGPoint(x: r.minX + p.x * r.width, y: r.minY + p.y * r.height)
            ctx.fillEllipse(in: CGRect(x: c.x - 9, y: c.y - 9, width: 18, height: 18))
        }
    }
}

struct TrackpadMapView: NSViewRepresentable {
    let model: AppModel
    let highlight: Int

    func makeNSView(context: Context) -> TrackpadMapNSView {
        let v = TrackpadMapNSView(frame: .zero)
        model.register(v)
        v.highlight = highlight
        return v
    }

    func updateNSView(_ view: TrackpadMapNSView, context: Context) { view.highlight = highlight }
}
