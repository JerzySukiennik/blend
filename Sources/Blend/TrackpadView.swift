// Blend app: feeds raw trackpad touches into the gesture board and connects its gestures to the session, haptics and the tour.
import AppKit
import BlendKit

enum TrackpadZones {
    static let strip = CGFloat(TouchBoard.strip)
    static let corner = CGFloat(TouchBoard.corner)
}

final class TrackpadView: NSView {
    weak var model: AppModel? {
        didSet { wire() }
    }
    var captured = false
    private let board = TouchBoard()
    private var filterReturn: Timer?
    private var lastHaptic = 0.0
    private var now = 0.0
    private var scratchTravel = 0.0
    private var fadeTravel = 0.0

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.indirect]
        wantsRestingTouches = true
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

    private func key(_ touch: NSTouch) -> AnyHashable { AnyHashable(touch.identity as! NSObject) }

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    private func wire() {
        guard let model else { return }
        let session = model.session
        board.onScratchBegin = { [weak self] deck in
            self?.scratchTravel = 0
            session.scratchBegin(deck)
        }
        board.onScratchMove = { [weak self] deck, frames, seconds in
            session.scratchMove(deck, frames: frames, seconds: seconds)
            guard let self else { return }
            self.scratchTravel += abs(frames)
            if model.tutorial == 1, self.scratchTravel > 20000 { model.advanceTutorial(from: 1) }
        }
        board.onScratchEnd = { deck in session.scratchEnd(deck) }
        board.onFilter = { deck, value in
            session.setFilter(deck, value)
            if model.tutorial == 2, abs(value) > 0.35 { model.advanceTutorial(from: 2) }
        }
        board.onFilterRelease = { [weak self] in self?.releaseFilter() }
        board.onFade = { [weak self] delta in
            guard let self else { return }
            let before = session.transition?.progress ?? 0
            session.crossfade(delta: delta)
            let after = session.transition?.progress ?? 0
            if (before < 0.5) != (after < 0.5) || (after >= 1 && before < 1) || (after <= 0 && before > 0), self.now - self.lastHaptic > 0.08 {
                self.haptic(.levelChange)
                self.lastHaptic = self.now
            }
            self.fadeTravel += abs(delta)
            if model.tutorial == 3, self.fadeTravel > 0.25 { model.advanceTutorial(from: 3) }
        }
        board.onFadeEnd = { [weak self] in
            self?.fadeTravel = 0
            session.crossfadeEnd()
        }
        board.onTap = { [weak self] deck in
            guard let self, self.captured else { return }
            session.playPause(deck)
            self.haptic(.generic)
            if model.tutorial == 4 { model.advanceTutorial(from: 4) }
        }
    }

    private func points(_ event: NSEvent, _ phase: NSTouch.Phase) -> [TouchPoint] {
        event.touches(matching: phase, in: self).map { touch in
            let p = touch.normalizedPosition
            if touch.deviceSize.height > 0 {
                board.width = Double(touch.deviceSize.width)
                board.height = Double(touch.deviceSize.height)
                board.perCm = 72 / 2.54
            }
            return TouchPoint(id: key(touch), x: Double(p.x), y: Double(p.y), resting: touch.isResting)
        }
    }

    private func resting(_ event: NSEvent) -> Set<AnyHashable> {
        Set(event.touches(matching: .touching, in: self).filter(\.isResting).map(key))
    }

    private func publish() {
        guard let model else { return }
        model.touches = board.points.map { CGPoint(x: $0.x, y: $0.y) }
        if board.height > 0 { model.touchAspect = CGFloat(board.width / board.height) }
        model.wake()
    }

    override func touchesBegan(with event: NSEvent) {
        guard captured, let model else { return }
        now = event.timestamp
        let fresh = points(event, .began)
        board.began(fresh, live: Set(event.touches(matching: .any, in: self).map(key)), time: now)
        board.rest(resting(event))
        for touch in fresh {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.captured else { return }
                self.board.hold(touch.id)
            }
        }
        publish()
        if model.tutorial == 0, !board.points.isEmpty { model.advanceTutorial(from: 0) }
    }

    override func touchesMoved(with event: NSEvent) {
        guard captured else { return }
        now = event.timestamp
        board.moved(points(event, .moved), time: now)
        board.rest(resting(event))
        publish()
    }

    override func touchesEnded(with event: NSEvent) { finish(event, cancelled: false) }
    override func touchesCancelled(with event: NSEvent) { finish(event, cancelled: true) }

    private func finish(_ event: NSEvent, cancelled: Bool) {
        now = event.timestamp
        board.ended(event.touches(matching: [.ended, .cancelled], in: self).map(key), cancelled: cancelled || !captured, time: now)
        publish()
    }

    private func releaseFilter() {
        guard filterReturn == nil || filterReturn?.isValid == false else { return }
        filterReturn = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self, let model = self.model else {
                timer.invalidate()
                return
            }
            let busy = self.board.relax()
            model.wake()
            if !busy { timer.invalidate() }
        }
    }

    func releaseAll() {
        board.releaseAll()
        model?.touches = []
    }
}
