// Blend kit: transition plans. A technique picks the choreography: parameter lanes over progress 0...1 plus timed cues, playable by the beat clock or scrubbed by hand. One drum kit, one bass and one lead vocal sound at a time.
import BlendEngine
import Foundation

public enum Move: String, CaseIterable, Identifiable {
    case mix, vocal, beat, build, drop, loop, roll, echo, brake, spin, quick

    public var id: String { rawValue }
    public var label: String { self == .quick ? "SWITCH" : rawValue.uppercased() }
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
        case .quick: return "N"
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
        case .quick: return "Switch to the next song at the next good moment"
        }
    }
}

public enum Effect: Int32, CaseIterable, Identifiable {
    case radio = 1, glass, hall, lofi

    public var id: Int32 { rawValue }
    public var label: String { ["RADIO", "GLASS", "HALL", "LO-FI"][Int(rawValue) - 1] }
    public var help: String {
        ["Sounds like a small radio", "Sounds like the party is behind a window", "Sounds like a big hall", "Sounds like an old game console"][Int(rawValue) - 1]
    }
}

public enum Technique: String, CaseIterable, Identifiable {
    case swap, melt, carry, ride, loop, chop, bridge, roll, wash, spin

    public var id: String { rawValue }
    public var label: String { rawValue.uppercased() }
    public var blends: Bool { self != .roll && self != .wash && self != .spin }
    var scripted: Bool { self == .loop || self == .chop || self == .bridge }
    var needsStems: Bool { self == .melt || self == .carry || self == .loop || self == .bridge }
    public var help: String {
        switch self {
        case .swap: return "New song comes in thin, the lows trade places on the phrase"
        case .melt: return "Old song sinks under a low-pass while the new one opens up"
        case .carry: return "Old vocal keeps singing over the new beat"
        case .ride: return "New drums ride underneath, then a clean swap"
        case .loop: return "Old song locks into a shrinking loop, new one lands on the one"
        case .chop: return "The two songs trade beats, then the new one takes over"
        case .bridge: return "Old drums loop and glide to the new tempo, new song comes in on top"
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
    public var toDelay = 0.0
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

typealias Seg = (Double, Double, Double)

enum Lanes {
    static let thin = 0.45
    static let air = 0.62
    static let stage = 0.86

    static func blend(_ tech: Technique, from f: Int, to t: Int, fromStems: Bool, toStems: Bool, toDrums: Bool, toPlaying: Bool, beats: Double, current: (Int, Int32) -> Double) -> [Lane] {
        var out: [Lane] = []
        func lane(_ deck: Int, _ param: Int32, initial: Double?, _ segs: [Seg]) {
            let isTo = deck == t
            let apply = isTo && !toPlaying && initial != nil
            let base = apply ? initial! : current(deck, param)
            out.append(Lane(deck: deck, param: param, base: base, applyBase: apply, segs: segs.map { (p0: $0.0, p1: $0.1, v: $0.2) }))
        }
        let vocals = Int32(BE_P_STEM0), drums = Int32(BE_P_STEM1), bass = Int32(BE_P_STEM2), music = Int32(BE_P_STEM3)
        let volume = Int32(BE_P_VOLUME), filter = Int32(BE_P_FILTER), echo = Int32(BE_P_ECHO)
        let q: Double = 1 / beats
        let e: Double = 0.05 * q
        let late = tech == .ride || tech == .bridge
        let mid: Double = late ? 0.75 : 0.5
        let s0: Double = mid - q
        let pre: Double = min(0.4375, s0)
        let c: Double = 1 - 8 * q
        let none: [Seg] = []
        let open: Seg = (s0, mid, 1.0)
        let shut: Seg = (s0, mid, 0.0)
        let clear: Seg = (s0, mid, 0.0)
        let rise: Seg = (mid, min(1.0, mid + 0.125), 1.0)
        let land: Seg = (1 - e, 1.0, 1.0)
        let drop: Seg = (1 - e, 1.0, 0.0)
        let settle: Seg = (0.0625, 0.1875, stage)
        var gateIn: [Seg] = []
        var gateOut: [Seg] = []
        let steps: [(Double, Double)] = [(2, 1), (4, 0), (5, 1), (6, 0), (7, 1)]
        for (beat, level) in steps {
            gateIn.append((c + beat * q - e, c + beat * q, level))
            gateOut.append((c + beat * q - e, c + beat * q, 1 - level))
        }

        if tech == .loop, toStems {
            lane(t, drums, initial: 0, [(0.0, 0.125, 1.0)])
            for stem in [music, bass, vocals] { lane(t, stem, initial: 0, [land]) }
            lane(t, volume, initial: 1, none)
            lane(t, filter, initial: air, [(1 - e, 1.0, 0.0)])
        } else if tech == .loop {
            lane(t, volume, initial: 0, [land])
            lane(t, filter, initial: 0, none)
        } else if tech == .chop, toStems {
            lane(t, drums, initial: 0, [(0.0, min(0.125, c / 2), 1.0)])
            for stem in [music, bass, vocals] { lane(t, stem, initial: 0, [(c, c + q, 1.0)]) }
            let mute: Seg = (c - e, c, 0.0)
            lane(t, volume, initial: 1, [mute] + gateIn)
            lane(t, filter, initial: air, [(c, c + q, 0.0)])
        } else if tech == .chop {
            lane(t, volume, initial: 0, gateIn)
            lane(t, filter, initial: 0, none)
        } else if tech == .bridge, toStems {
            lane(t, drums, initial: 0, [(0.5, 0.625, 1.0)])
            for stem in [music, bass, vocals] { lane(t, stem, initial: 0, [open]) }
            lane(t, volume, initial: 1, none)
            lane(t, filter, initial: air, [clear])
        } else if toStems {
            var tune: [Seg] = [open]
            var tone: [Seg] = [clear]
            if tech != .ride {
                tune = [(0.25, pre, 0.7), open]
                tone = [(0.25, pre, thin), clear]
            } else if !toDrums {
                tune = [(0.0, 0.25, 0.6), open]
            }
            let voice: Seg = tech == .carry ? (0.875, 1.0, 1.0) : (mid, mid + q, 1.0)
            lane(t, drums, initial: 0, [(0.0, late ? 0.1875 : 0.125, 1.0)])
            lane(t, music, initial: 0, tune)
            lane(t, vocals, initial: 0, [voice])
            lane(t, bass, initial: 0, [open])
            lane(t, volume, initial: stage, [rise])
            lane(t, filter, initial: air, tone)
        } else {
            lane(t, volume, initial: 0, [(0.0, 0.4, stage), rise])
            lane(t, filter, initial: thin, [clear])
        }
        lane(t, echo, initial: 0, none)

        if tech == .loop {
            lane(f, filter, initial: nil, [(0.5, 0.75, 0.3), (0.75, 1.0, 0.68)])
            lane(f, echo, initial: nil, [(1 - 2 * q, 1 - q, 0.6)])
            lane(f, volume, initial: nil, [drop])
        } else if tech == .chop {
            lane(f, volume, initial: nil, gateOut)
            lane(f, echo, initial: nil, [(c + 6 * q, c + 6.5 * q, 0.45)])
        } else if tech == .bridge, fromStems {
            lane(f, vocals, initial: nil, [(0.0, 0.125, 0.0)])
            lane(f, music, initial: nil, [(0.0625, 0.25, 0.0)])
            lane(f, bass, initial: nil, [(0.125, 0.25, 0.0)])
            lane(f, filter, initial: nil, [(0.5, s0, 0.5)])
            lane(f, echo, initial: nil, [(0.125, 0.1875, 0.4), (0.25, 0.3125, 0.0), (0.6875, s0, 0.45), (mid, mid + q, 0.0)])
            lane(f, drums, initial: nil, [shut])
        } else if tech == .ride, fromStems {
            lane(f, filter, initial: nil, [(0.375, s0, 0.4), (s0, mid, air)])
            lane(f, echo, initial: nil, [(mid - 0.125, s0, 0.5), (mid, mid + q, 0.0)])
            lane(f, volume, initial: nil, [settle])
            for stem in [vocals, drums, bass, music] { lane(f, stem, initial: nil, [shut]) }
        } else if tech == .melt, fromStems {
            lane(f, filter, initial: nil, [(0.125, s0, -0.3), (mid, 0.875, -0.72)])
            lane(f, volume, initial: nil, [settle])
            lane(f, vocals, initial: nil, [(pre, 0.5, 0.0)])
            lane(f, bass, initial: nil, [shut])
            lane(f, drums, initial: nil, [shut])
            lane(f, music, initial: nil, [(0.625, 0.9375, 0.0)])
        } else if tech == .carry, fromStems {
            lane(f, bass, initial: nil, [shut])
            lane(f, drums, initial: nil, [shut])
            lane(f, music, initial: nil, [(mid, 0.625, 0.0)])
            lane(f, filter, initial: nil, [(s0, mid, 0.3)])
            lane(f, volume, initial: nil, [settle])
            lane(f, echo, initial: nil, [(0.8125, 0.875, 0.5), (0.9375, 1.0, 0.0)])
            lane(f, vocals, initial: nil, [(0.875, 0.9375, 0.0)])
        } else {
            lane(f, filter, initial: nil, [(s0, mid, thin), (0.5, 0.875, 0.7)])
            lane(f, echo, initial: nil, [(0.625, 0.8125, 0.4), (0.9375, 1.0, 0.0)])
            if fromStems {
                lane(f, volume, initial: nil, [settle])
                lane(f, bass, initial: nil, [shut])
                lane(f, drums, initial: nil, [shut])
                lane(f, vocals, initial: nil, [(pre, 0.5, 0.0)])
                lane(f, music, initial: nil, [(0.5625, 0.875, 0.0)])
            } else {
                lane(f, volume, initial: nil, [settle, (0.5625, 0.9375, 0.0)])
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

    static func bridgeCues(deck: Int, beats: Double, trackBeat: Double) -> [Cue] {
        [Cue(type: Int32(BE_EV_LOOP), deck: deck, p: 0.25, value: beats >= 64 ? 8 : 4, from: trackBeat),
         Cue(type: Int32(BE_EV_UNLOOP), deck: deck, p: 1, value: 0, from: .nan)]
    }
}
