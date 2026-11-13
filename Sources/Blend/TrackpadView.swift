// Blend app: turns raw trackpad touches into console gestures (platter scratch, two-finger filter, crossfade strip, corner taps).
import AppKit
import BlendKit

enum TrackpadZones {
    static let strip: CGFloat = 0.2
    static let corner: CGFloat = 0.15
}

final class TrackpadView: NSView {
    private enum Zone: Equatable {
        case disc(Int), fader, corner(Int)
    }

    private struct Finger {
        var zone: Zone
        var start: CGPoint
        var last: CGPoint
        var began: TimeInterval
        var moved: CGFloat = 0
    }

    weak var model: AppModel?
    var captured = false
    private var fingers: [AnyHashable: Finger] = [:]
    private var scratching: [AnyHashable?] = [nil, nil]
    private var filtering = [false, false]
    private var filterValue: [Float] = [0, 0]
    private var filterReturn: Timer?
    private var faderFinger: AnyHashable?
    private var lastHaptic = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = false
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { captured ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func rotate(with event: NSEvent) {}
    override func swipe(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}

    private func zone(at p: CGPoint) -> Zone {
        if p.y < TrackpadZones.strip {
            if p.x < TrackpadZones.corner { return .corner(0) }
            if p.x > 1 - TrackpadZones.corner { return .corner(1) }
            return .fader
        }
        return .disc(p.x < 0.5 ? 0 : 1)
    }

    private func key(_ touch: NSTouch) -> AnyHashable { AnyHashable(touch.identity as! NSObject) }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func publish(_ event: NSEvent) {
        guard let model else { return }
        let all = event.touches(matching: .touching, in: self)
        model.touches = all.map(\.normalizedPosition)
        if let any = all.first, any.deviceSize.height > 0 { model.touchAspect = any.deviceSize.width / any.deviceSize.height }
        model.touch()
    }

    override func touchesBegan(with event: NSEvent) {
        guard captured, let model else { return }
        for touch in event.touches(matching: .began, in: self) where !touch.isResting {
            let p = touch.normalizedPosition
            fingers[key(touch)] = Finger(zone: zone(at: p), start: p, last: p, began: event.timestamp)
        }
        publish(event)
        if model.tutorial == 0 { model.advanceTutorial(from: 0) }
        for d in 0..<2 where count(in: .disc(d)) >= 2 { beginFilter(d) }
    }

    private func count(in zone: Zone) -> Int { fingers.values.filter { $0.zone == zone }.count }

    private func beginFilter(_ deck: Int) {
        guard let model else { return }
        if let id = scratching[deck] {
            _ = id
            scratching[deck] = nil
            model.session.scratchEnd(deck)
        }
        filtering[deck] = true
        filterReturn?.invalidate()
    }

    override func touchesMoved(with event: NSEvent) {
        guard captured, let model else { return }
        let session = model.session
        var filterDelta: [CGFloat] = [0, 0]
        var filterCount = [0, 0]
        for touch in event.touches(matching: .moved, in: self) {
            let id = key(touch)
            guard var f = fingers[id] else { continue }
            let p = touch.normalizedPosition
            let size = touch.deviceSize
            let dx = (p.x - f.last.x) * size.width, dy = (p.y - f.last.y) * size.height
            f.moved += abs(dx) + abs(dy)
            switch f.zone {
            case .disc(let deck):
                if filtering[deck] {
                    filterDelta[deck] += p.y - f.last.y
                    filterCount[deck] += 1
                } else {
                    if scratching[deck] == nil, count(in: .disc(deck)) == 1, f.moved > 3 || event.timestamp - f.began > 0.09 {
                        scratching[deck] = id
                        session.scratchBegin(deck)
                    }
                    if scratching[deck] == id {
                        let discH = size.height * (1 - TrackpadZones.strip)
                        let center = CGPoint(x: size.width * (deck == 0 ? 0.25 : 0.75), y: size.height * TrackpadZones.strip + discH / 2)
                        let a = CGPoint(x: f.last.x * size.width - center.x, y: f.last.y * size.height - center.y)
                        let b = CGPoint(x: p.x * size.width - center.x, y: p.y * size.height - center.y)
                        let ra = hypot(a.x, a.y), rb = hypot(b.x, b.y)
                        var angle: CGFloat
                        if min(ra, rb) < discH * 0.14 {
                            angle = -dx / (discH * 0.3)
                        } else {
                            angle = atan2(a.x * b.y - a.y * b.x, a.x * b.x + a.y * b.y)
                        }
                        session.scratchMove(deck, frames: Double(-angle) / (2 * .pi) * 1.8 * 44100)
                        if model.tutorial == 1, f.moved > 60 { model.advanceTutorial(from: 1) }
                    }
                }
            case .fader:
                if faderFinger == nil, f.moved > 2 { faderFinger = id }
                if faderFinger == id {
                    let before = session.transition?.progress ?? 0
                    session.crossfade(delta: Double((p.x - f.last.x) / (1 - 2 * TrackpadZones.corner)))
                    let after = session.transition?.progress ?? 0
                    if (before < 0.5) != (after < 0.5) || (after >= 1 && before < 1) || (after <= 0 && before > 0) {
                        if event.timestamp - lastHaptic > 0.08 {
                            haptic(.levelChange)
                            lastHaptic = event.timestamp
                        }
                    }
                    if model.tutorial == 3, abs(p.x - f.start.x) > 0.2 { model.advanceTutorial(from: 3) }
                }
            case .corner:
                break
            }
            f.last = p
            fingers[id] = f
        }
        for d in 0..<2 where filtering[d] && filterCount[d] > 0 {
            filterValue[d] = max(-1, min(1, filterValue[d] + Float(filterDelta[d] / CGFloat(filterCount[d])) * 2.4))
            session.setFilter(d, filterValue[d])
            if model.tutorial == 2, abs(filterValue[d]) > 0.35 { model.advanceTutorial(from: 2) }
        }
        publish(event)
    }

    override func touchesEnded(with event: NSEvent) { finish(event, cancelled: false) }
    override func touchesCancelled(with event: NSEvent) { finish(event, cancelled: true) }

    private func finish(_ event: NSEvent, cancelled: Bool) {
        guard let model else { return }
        let session = model.session
        for touch in event.touches(matching: [.ended, .cancelled], in: self) {
            let id = key(touch)
            guard let f = fingers.removeValue(forKey: id) else { continue }
            switch f.zone {
            case .disc(let deck):
                if scratching[deck] == id {
                    scratching[deck] = nil
                    session.scratchEnd(deck)
                }
                if filtering[deck], count(in: .disc(deck)) == 0 {
                    filtering[deck] = false
                    releaseFilter()
                }
            case .fader:
                if faderFinger == id {
                    faderFinger = nil
                    session.crossfadeEnd()
                }
            case .corner(let deck):
                if !cancelled, captured, f.moved < 6, event.timestamp - f.began < 0.45 {
                    session.playPause(deck)
                    haptic(.generic)
                    if model.tutorial == 4 { model.advanceTutorial(from: 4) }
                }
            }
        }
        publish(event)
    }

    private func releaseFilter() {
        guard filterReturn == nil || filterReturn?.isValid == false else { return }
        filterReturn = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let model = self.model else {
                timer.invalidate()
                return
            }
            var busy = false
            for d in 0..<2 where !self.filtering[d] && self.filterValue[d] != 0 {
                self.filterValue[d] *= 0.8
                if abs(self.filterValue[d]) < 0.01 { self.filterValue[d] = 0 }
                model.session.setFilter(d, self.filterValue[d])
                busy = busy || self.filterValue[d] != 0
            }
            model.touch()
            if !busy { timer.invalidate() }
        }
    }

    func releaseAll() {
        guard let model else { return }
        for d in 0..<2 {
            if scratching[d] != nil {
                scratching[d] = nil
                model.session.scratchEnd(d)
            }
            filtering[d] = false
        }
        if faderFinger != nil {
            faderFinger = nil
            model.session.crossfadeEnd()
        }
        fingers.removeAll()
        model.touches = []
        releaseFilter()
    }
}
