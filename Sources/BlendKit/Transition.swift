// Blend kit: transition plans. A blend is a set of parameter lanes over progress 0...1, playable by the beat clock or scrubbed by hand.
import BlendEngine
import Foundation

public enum Move: String, CaseIterable, Identifiable {
    case mix, vocal, beat, build, drop, loop, echo, brake

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var key: String {
        switch self {
        case .mix: return "space"
        case .vocal: return "V"
        case .beat: return "B"
        case .build: return "U"
        case .drop: return "D"
        case .loop: return "L"
        case .echo: return "E"
        case .brake: return "K"
        }
    }
    public var help: String {
        switch self {
        case .mix: return "Blend into the next song"
        case .vocal: return "Next song's vocal over this beat"
        case .beat: return "This vocal over the next song's beat"
        case .build: return "Build up, then drop the next song"
        case .drop: return "Jump to the next drop"
        case .loop: return "Loop the last 4 beats"
        case .echo: return "Echo out into the next song"
        case .brake: return "Vinyl brake into the next song"
        }
    }
}

struct Lane {
    var deck: Int
    var param: Int32
    var base: Double
    var applyBase: Bool
    var segs: [(p0: Double, p1: Double, v: Double)]

    func value(at p: Double) -> Double {
        var v = base
        for s in segs {
            if p >= s.p1 {
                v = s.v
            } else if p > s.p0 {
                v += (s.v - v) * (p - s.p0) / (s.p1 - s.p0)
                break
            } else {
                break
            }
        }
        return v
    }
}

public struct Transition {
    public enum Style: String {
        case blend, build, echo, brake
    }

    public var style: Style
    public var from: Int
    public var to: Int
    public var startBeat: Double
    public var length: Double
    public var toTrackBeat: Double
    public var tempoFrom: Double
    public var tempoTo: Double
    public var tag: Int
    public var manual = false
    public var progress = 0.0
    public var committed = false
    public var toWasPlaying = false
    public var pitch = 0
    public var clash = false
    var lanes: [Lane] = []

    public var endBeat: Double { startBeat + length }

    public func progress(atBeat beat: Double) -> Double {
        manual ? progress : min(1, max(0, (beat - startBeat) / max(0.001, length)))
    }
}

enum Lanes {
    static let thin = 0.45

    static func blend(from f: Int, to t: Int, fromStems: Bool, toStems: Bool, toDrums: Bool, clash: Bool, toPlaying: Bool, beat q: Double, current: (Int, Int32) -> Double) -> [Lane] {
        var out: [Lane] = []
        func lane(_ deck: Int, _ param: Int32, initial: Double?, _ segs: [(Double, Double, Double)]) {
            let isTo = deck == t
            let apply = isTo && !toPlaying && initial != nil
            let base = apply ? initial! : current(deck, param)
            out.append(Lane(deck: deck, param: param, base: base, applyBase: apply, segs: segs.map { (p0: $0.0, p1: $0.1, v: $0.2) }))
        }
        let vocals = Int32(BE_P_STEM0), drums = Int32(BE_P_STEM1), bass = Int32(BE_P_STEM2), music = Int32(BE_P_STEM3)
        let volume = Int32(BE_P_VOLUME), filter = Int32(BE_P_FILTER), echo = Int32(BE_P_ECHO)
        let mid = clash ? 0.75 : 0.5
        let swap = (mid - q, mid)
        if toStems {
            lane(t, drums, initial: 0, [(0, clash ? 0.1875 : 0.125, 1)])
            lane(t, music, initial: 0, !clash ? [(0.125, 0.375, 1)] : toDrums ? [(swap.0, swap.1, 1)] : [(0, 0.25, 0.6), (swap.0, swap.1, 1)])
            lane(t, vocals, initial: 0, [(mid, mid + q, 1)])
            lane(t, bass, initial: 0, [(swap.0, swap.1, 1)])
            lane(t, volume, initial: 1, [(0, q, 1)])
            lane(t, filter, initial: thin, [(swap.0, swap.1, 0)])
        } else {
            lane(t, volume, initial: 0, [(0, 0.4, 1)])
            lane(t, filter, initial: thin, [(swap.0, swap.1, 0)])
        }
        lane(t, echo, initial: 0, [])
        if fromStems, clash {
            lane(f, filter, initial: nil, [(0.375, swap.0, 0.4), (swap.0, swap.1, 0.62)])
            lane(f, echo, initial: nil, [(mid - 0.125, swap.0, 0.75), (mid, mid + q, 0)])
            for stem in [vocals, drums, bass, music] { lane(f, stem, initial: nil, [(swap.0, swap.1, 0)]) }
        } else if fromStems {
            lane(f, filter, initial: nil, [(swap.0, swap.1, thin), (0.5, 0.875, 0.7)])
            lane(f, bass, initial: nil, [(swap.0, swap.1, 0)])
            lane(f, vocals, initial: nil, [(0.4375, 0.5, 0)])
            lane(f, music, initial: nil, [(0.5625, 0.875, 0)])
            lane(f, drums, initial: nil, [(0.5, 0.8125, 0)])
            lane(f, echo, initial: nil, [(0.625, 0.8125, 0.55), (0.9375, 1, 0)])
        } else {
            lane(f, filter, initial: nil, [(swap.0, swap.1, thin), (0.5, 0.875, 0.7)])
            lane(f, echo, initial: nil, [(0.625, 0.8125, 0.55), (0.9375, 1, 0)])
            lane(f, volume, initial: nil, [(0.5625, 0.9375, 0)])
        }
        return out
    }
}
