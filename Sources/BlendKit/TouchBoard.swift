// Blend kit: turns trackpad touch points into console gestures (platter scratch, two-finger filter, crossfade strip, corner taps). No AppKit, so the rules can be tested offline.
import Foundation

public struct TouchPoint {
    public var id: AnyHashable
    public var x: Double
    public var y: Double
    public var resting: Bool

    public init(id: AnyHashable, x: Double, y: Double, resting: Bool = false) {
        self.id = id
        self.x = x
        self.y = y
        self.resting = resting
    }
}

public final class TouchBoard {
    public enum Zone: Equatable {
        case disc(Int), fader, corner(Int)
    }

    public static let strip = 0.2
    public static let corner = 0.15

    private struct Finger {
        var zone: Zone
        var start: (x: Double, y: Double)
        var last: (x: Double, y: Double)
        var began: Double
        var stamp = 0.0
        var moved = 0.0
        var active: Bool
        var passenger = false
    }

    public static let secondsPerCm = 0.055

    public var width = 160.0
    public var height = 100.0
    public var perCm = 10.0
    public var onScratchBegin: (Int) -> Void = { _ in }
    public var onScratchMove: (Int, Double, Double) -> Void = { _, _, _ in }
    public var onScratchEnd: (Int) -> Void = { _ in }
    public var onFilter: (Int, Float) -> Void = { _, _ in }
    public var onFilterRelease: () -> Void = {}
    public var onFade: (Double) -> Void = { _ in }
    public var onFadeEnd: () -> Void = {}
    public var onTap: (Int) -> Void = { _ in }

    public private(set) var filtering = [false, false]
    public private(set) var filterValue: [Float] = [0, 0]
    private var fingers: [AnyHashable: Finger] = [:]
    private var scratching: [AnyHashable?] = [nil, nil]
    private var faderFinger: AnyHashable?

    public init() {}

    public var points: [(x: Double, y: Double)] { fingers.values.filter { $0.active && !$0.passenger }.map(\.last) }

    private func zone(_ x: Double, _ y: Double) -> Zone {
        if y < Self.strip {
            if x < Self.corner { return .corner(0) }
            if x > 1 - Self.corner { return .corner(1) }
            return .fader
        }
        return .disc(x < 0.5 ? 0 : 1)
    }

    private func count(_ deck: Int) -> Int { fingers.values.filter { $0.active && !$0.passenger && $0.zone == .disc(deck) }.count }

    private func adopt(_ t: TouchPoint, time: Double) {
        var z = zone(t.x, t.y)
        if !t.resting {
            for (other, f) in fingers where other != t.id && f.active && faderFinger != other && time - f.began < 0.2 && abs(f.last.x - t.x) < 0.3 && abs(f.last.y - t.y) < 0.5 {
                var deck = (f.last.x + t.x) / 2 < 0.5 ? 0 : 1
                if case .disc(let d) = f.zone { deck = d }
                z = .disc(deck)
                fingers[other]?.zone = z
                break
            }
        }
        fingers[t.id] = Finger(zone: z, start: (t.x, t.y), last: (t.x, t.y), began: time, active: !t.resting)
    }

    private func engageFilters() {
        for d in 0..<2 where count(d) >= 2 && !filtering[d] {
            let pair = fingers.filter { $0.value.active && !$0.value.passenger && $0.value.zone == .disc(d) }.sorted { $0.value.began < $1.value.began }
            if let first = pair.first, let late = pair.last, late.value.began - first.value.began > 0.35, first.value.moved > 12 {
                fingers[late.key]?.passenger = true
                continue
            }
            if scratching[d] != nil {
                scratching[d] = nil
                onScratchEnd(d)
            }
            filtering[d] = true
        }
    }

    private func drop(_ id: AnyHashable, tap: Bool, time: Double) {
        guard let f = fingers.removeValue(forKey: id) else { return }
        if faderFinger == id {
            faderFinger = nil
            onFadeEnd()
        }
        switch f.zone {
        case .disc(let deck):
            if scratching[deck] == id {
                scratching[deck] = nil
                onScratchEnd(deck)
            }
            if filtering[deck], count(deck) == 0 {
                filtering[deck] = false
                onFilterRelease()
            }
        case .corner(let deck):
            if tap, f.moved < 6, time - f.began < 0.45 { onTap(deck) }
        case .fader:
            break
        }
    }

    public func began(_ touches: [TouchPoint], live: Set<AnyHashable>, time: Double) {
        for id in Array(fingers.keys) where !live.contains(id) { drop(id, tap: false, time: time) }
        for t in touches { adopt(t, time: time) }
        engageFilters()
    }

    public func rest(_ ids: Set<AnyHashable>) {
        for id in ids where fingers[id]?.active == true && fingers[id]?.passenger == false && faderFinger != id && !scratching.contains(where: { $0 == id }) {
            fingers[id]?.passenger = true
        }
        for d in 0..<2 where filtering[d] && count(d) == 0 {
            filtering[d] = false
            onFilterRelease()
        }
    }

    public func hold(_ id: AnyHashable) {
        guard let f = fingers[id], f.active, !f.passenger, case .disc(let deck) = f.zone, scratching[deck] == nil, !filtering[deck], count(deck) == 1 else { return }
        scratching[deck] = id
        onScratchBegin(deck)
    }

    public func moved(_ touches: [TouchPoint], time: Double) {
        var delta = [0.0, 0.0], n = [0, 0]
        for t in touches {
            guard var f = fingers[t.id] else {
                if !t.resting { adopt(t, time: time) }
                continue
            }
            if f.passenger {
                f.last = (t.x, t.y)
                fingers[t.id] = f
                continue
            }
            if !f.active {
                if !t.resting {
                    f.active = true
                    f.began = time
                    f.start = (t.x, t.y)
                    f.moved = 0
                }
                f.last = (t.x, t.y)
                fingers[t.id] = f
                continue
            }
            let dx = (t.x - f.last.x) * width, dy = (t.y - f.last.y) * height
            f.moved += abs(dx) + abs(dy)
            let upward = abs(t.y - f.start.y) * height > abs(t.x - f.start.x) * width * 1.5
            switch f.zone {
            case .corner where f.moved > 8:
                if upward {
                    f.zone = .disc(t.x < 0.5 ? 0 : 1)
                } else if faderFinger == nil {
                    f.zone = .fader
                    faderFinger = t.id
                }
            case .fader where faderFinger == nil && f.moved > 4:
                if upward {
                    f.zone = .disc(t.x < 0.5 ? 0 : 1)
                } else {
                    faderFinger = t.id
                }
            default:
                break
            }
            fingers[t.id] = f
            switch f.zone {
            case .disc(let deck):
                if filtering[deck] {
                    delta[deck] += t.y - f.last.y
                    n[deck] += 1
                } else {
                    if scratching[deck] == nil, count(deck) == 1, f.moved > 3 || time - f.began > 0.09 {
                        scratching[deck] = t.id
                        onScratchBegin(deck)
                    }
                    if scratching[deck] == t.id {
                        let discH = height * (1 - Self.strip)
                        let cx = width * (deck == 0 ? 0.25 : 0.75), cy = height * Self.strip + discH / 2
                        let ax = f.last.x * width - cx, ay = f.last.y * height - cy
                        let bx = t.x * width - cx, by = t.y * height - cy
                        let ra = hypot(ax, ay), rb = hypot(bx, by)
                        let arc = min(ra, rb) < discH * 0.14 ? dx : -atan2(ax * by - ay * bx, ax * bx + ay * by) * (ra + rb) / 2
                        onScratchMove(deck, arc / perCm * Self.secondsPerCm * 44100, f.stamp > 0 ? time - f.stamp : 0)
                    }
                }
            case .fader:
                if faderFinger == t.id { onFade((t.x - f.last.x) / (1 - 2 * Self.corner)) }
            case .corner:
                break
            }
            f.last = (t.x, t.y)
            f.stamp = time
            fingers[t.id] = f
        }
        engageFilters()
        for d in 0..<2 where filtering[d] && n[d] > 0 {
            filterValue[d] = max(-1, min(1, filterValue[d] + Float(delta[d] / Double(n[d])) * 2.4))
            onFilter(d, filterValue[d])
        }
    }

    public func ended(_ ids: [AnyHashable], cancelled: Bool, time: Double) {
        for id in ids { drop(id, tap: !cancelled, time: time) }
    }

    public func relax() -> Bool {
        var busy = false
        for d in 0..<2 where !filtering[d] && filterValue[d] != 0 {
            filterValue[d] *= 0.8
            if abs(filterValue[d]) < 0.01 { filterValue[d] = 0 }
            onFilter(d, filterValue[d])
            busy = busy || filterValue[d] != 0
        }
        return busy
    }

    public func releaseAll() {
        for d in 0..<2 {
            if scratching[d] != nil {
                scratching[d] = nil
                onScratchEnd(d)
            }
            filtering[d] = false
        }
        if faderFinger != nil {
            faderFinger = nil
            onFadeEnd()
        }
        fingers.removeAll()
        onFilterRelease()
    }
}
