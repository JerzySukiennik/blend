// Blend kit: transition plans. A technique picks the choreography: parameter lanes over progress 0...1 plus timed cues, playable by the beat clock or scrubbed by hand.
import BlendEngine
import Foundation

public enum Move: String, CaseIterable, Identifiable {
    case mix, vocal, beat, build, drop, loop, roll, echo, brake, spin

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
        case .roll: return "R"
        case .echo: return "E"
        case .brake: return "K"
        case .spin: return "X"
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
        case .roll: return "Hold to stutter the beat, release to drop back in"
        case .echo: return "Echo out into the next song"
        case .brake: return "Vinyl brake into the next song"
        case .spin: return "Spin the record back into the next song"
        }
    }
}

public enum Technique: String, CaseIterable, Identifiable {
    case swap, melt, carry, ride, loop, chop, roll, wash, spin

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var blends: Bool { self != .roll && self != .wash && self != .spin }
    var scripted: Bool { self == .loop || self == .chop }
    var needsStems: Bool { self == .melt || self == .carry || self == .loop }
    public var help: String {
        switch self {
        case .swap: return "New song comes in thin, the lows trade places on the phrase"
        case .melt: return "Old song sinks under a low-pass while the new one opens up"
        case .carry: return "Old vocal keeps singing over the new beat"
        case .ride: return "New drums ride underneath, then a clean swap"
        case .loop: return "Old song locks into a shrinking loop, new one lands on the one"
        case .chop: return "The two songs trade beats, then the new one takes over"
        case .roll: return "Stutter build on the old song, new one drops in"
        case .wash: return "Old song washes out in filter and echo"
        case .spin: return "Spinback into the new song"
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

struct Cue {
    var type: Int32
    var deck: Int
    var p: Double
    var value: Double
    var from: Double
}

public struct Transition {
    public enum Style: String {
        case blend, build, echo, brake, spin
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
    public var wide = false
    public var twin = false
    public var technique: Technique = .swap
    public var name = ""
    var lanes: [Lane] = []
    var cues: [Cue] = []

    public var endBeat: Double { startBeat + length }
    public var label: String { name.isEmpty ? technique.label : name }

    public func progress(atBeat beat: Double) -> Double {
        manual ? progress : min(1, max(0, (beat - startBeat) / max(0.001, length)))
    }
}

enum Lanes {
    static let thin = 0.45

    static func blend(_ tech: Technique, from f: Int, to t: Int, fromStems: Bool, toStems: Bool, toDrums: Bool, toPlaying: Bool, beats: Double, current: (Int, Int32) -> Double) -> [Lane] {
        var out: [Lane] = []
        func lane(_ deck: Int, _ param: Int32, initial: Double?, _ segs: [(Double, Double, Double)]) {
            let isTo = deck == t
            let apply = isTo && !toPlaying && initial != nil
            let base = apply ? initial! : current(deck, param)
            out.append(Lane(deck: deck, param: param, base: base, applyBase: apply, segs: segs.map { (p0: $0.0, p1: $0.1, v: $0.2) }))
        }
        let vocals = Int32(BE_P_STEM0), drums = Int32(BE_P_STEM1), bass = Int32(BE_P_STEM2), music = Int32(BE_P_STEM3)
        let volume = Int32(BE_P_VOLUME), filter = Int32(BE_P_FILTER), echo = Int32(BE_P_ECHO)
        let q = 1 / beats, e = 0.05 * q
        let clash = tech == .ride
        let mid = clash ? 0.75 : 0.5
        let swap = (mid - q, mid)
        let land = (1 - e, 1.0)
        let c = 1 - 8 * q
        let gateIn: [(Double, Double, Double)] = [(c + 2 * q - e, c + 2 * q, 1), (c + 4 * q - e, c + 4 * q, 0), (c + 5 * q - e, c + 5 * q, 1), (c + 6 * q - e, c + 6 * q, 0), (c + 7 * q - e, c + 7 * q, 1)]
        let gateOut: [(Double, Double, Double)] = [(c + 2 * q - e, c + 2 * q, 0), (c + 4 * q - e, c + 4 * q, 1), (c + 5 * q - e, c + 5 * q, 0), (c + 6 * q - e, c + 6 * q, 1), (c + 7 * q - e, c + 7 * q, 0)]

        switch tech {
        case .loop where toStems:
            lane(t, drums, initial: 0, [(0, 0.125, 1)])
            for stem in [music, bass, vocals] { lane(t, stem, initial: 0, [(land.0, land.1, 1)]) }
            lane(t, volume, initial: 1, [(0, q, 1)])
            lane(t, filter, initial: thin, [(land.0, land.1, 0)])
        case .loop:
            lane(t, volume, initial: 0, [(land.0, land.1, 1)])
            lane(t, filter, initial: 0, [])
        case .chop where toStems:
            lane(t, drums, initial: 0, [(0, min(0.125, c / 2), 1)])
            for stem in [music, bass, vocals] { lane(t, stem, initial: 0, [(c, c + q, 1)]) }
            lane(t, volume, initial: 1, [(c - e, c, 0)] + gateIn)
            lane(t, filter, initial: thin, [(c, c + q, 0)])
        case .chop:
            lane(t, volume, initial: 0, gateIn)
            lane(t, filter, initial: 0, [])
        default:
            if toStems {
                lane(t, drums, initial: 0, [(0, clash ? 0.1875 : 0.125, 1)])
                lane(t, music, initial: 0, !clash ? [(0.125, 0.375, 1)] : toDrums ? [(swap.0, swap.1, 1)] : [(0, 0.25, 0.6), (swap.0, swap.1, 1)])
                lane(t, vocals, initial: 0, tech == .carry ? [(0.875, 1, 1)] : [(mid, mid + q, 1)])
                lane(t, bass, initial: 0, [(swap.0, swap.1, 1)])
                lane(t, volume, initial: 1, [(0, q, 1)])
                lane(t, filter, initial: thin, [(swap.0, swap.1, 0)])
            } else {
                lane(t, volume, initial: 0, [(0, 0.4, 1)])
                lane(t, filter, initial: thin, [(swap.0, swap.1, 0)])
            }
        }
        lane(t, echo, initial: 0, [])

        switch tech {
        case .loop:
            lane(f, filter, initial: nil, [(0.5, 0.75, 0.3), (0.75, 1, 0.68)])
            lane(f, echo, initial: nil, [(1 - 2 * q, 1 - q, 0.8)])
            lane(f, volume, initial: nil, [(land.0, land.1, 0)])
        case .chop:
            lane(f, volume, initial: nil, gateOut)
            lane(f, echo, initial: nil, [(c + 6 * q, c + 6.5 * q, 0.6)])
        case .ride where fromStems:
            lane(f, filter, initial: nil, [(0.375, swap.0, 0.4), (swap.0, swap.1, 0.62)])
            lane(f, echo, initial: nil, [(mid - 0.125, swap.0, 0.75), (mid, mid + q, 0)])
            for stem in [vocals, drums, bass, music] { lane(f, stem, initial: nil, [(swap.0, swap.1, 0)]) }
        case .melt where fromStems:
            lane(f, filter, initial: nil, [(0.125, swap.0, -0.3), (swap.1, 0.875, -0.72)])
            lane(f, vocals, initial: nil, [(0.4375, 0.5, 0)])
            lane(f, bass, initial: nil, [(swap.0, swap.1, 0)])
            lane(f, drums, initial: nil, [(swap.0, swap.1, 0)])
            lane(f, music, initial: nil, [(0.625, 0.9375, 0)])
        case .carry where fromStems:
            lane(f, bass, initial: nil, [(swap.0, swap.1, 0)])
            lane(f, drums, initial: nil, [(swap.0, swap.1, 0)])
            lane(f, music, initial: nil, [(swap.1, 0.625, 0)])
            lane(f, filter, initial: nil, [(swap.0, swap.1, 0.3)])
            lane(f, echo, initial: nil, [(0.8125, 0.875, 0.7), (0.9375, 1, 0)])
            lane(f, vocals, initial: nil, [(0.875, 0.9375, 0)])
        default:
            lane(f, filter, initial: nil, [(swap.0, swap.1, thin), (0.5, 0.875, 0.7)])
            lane(f, echo, initial: nil, [(0.625, 0.8125, 0.55), (0.9375, 1, 0)])
            if fromStems {
                lane(f, bass, initial: nil, [(swap.0, swap.1, 0)])
                lane(f, vocals, initial: nil, [(0.4375, 0.5, 0)])
                lane(f, music, initial: nil, [(0.5625, 0.875, 0)])
                lane(f, drums, initial: nil, [(0.5, 0.8125, 0)])
            } else {
                lane(f, volume, initial: nil, [(0.5625, 0.9375, 0)])
            }
        }
        return out
    }

    static func loopCues(deck: Int, beats: Double, trackBeat: Double) -> [Cue] {
        var cues: [Cue] = []
        var at = beats / 2, len = beats / 8
        for _ in 0..<4 {
            cues.append(Cue(type: Int32(BE_EV_LOOP), deck: deck, p: at / beats, value: len, from: trackBeat))
            at += 2 * len
            len /= 2
        }
        cues.append(Cue(type: Int32(BE_EV_UNLOOP), deck: deck, p: 1, value: 0, from: .nan))
        return cues
    }
}
