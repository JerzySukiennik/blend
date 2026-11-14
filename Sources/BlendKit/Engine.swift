// Blend kit: thin Swift wrapper over the C engine (events, parameters, state).
import BlendEngine
import Foundation

public enum Stem: Int, CaseIterable {
    case vocals = 0, drums, bass, music

    public var label: String { ["VOCAL", "DRUMS", "BASS", "MUSIC"][rawValue] }
    public var param: Int32 { Int32(BE_P_STEM0) + Int32(rawValue) }
}

public enum Curve: Int32 {
    case linear = 0, smooth, easeIn, easeOut
}

public final class Engine {
    public let raw: OpaquePointer
    public let sampleRate: Double

    public init(sampleRate: Double = 44100) {
        self.sampleRate = sampleRate
        raw = be_create(sampleRate)
    }

    deinit { be_destroy(raw) }

    public var state: be_state {
        var s = be_state()
        be_get_state(raw, &s)
        return s
    }

    public func render(_ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>, _ frames: Int) {
        be_render(raw, left, right, Int32(frames))
    }

    public func collect() { be_collect(raw) }
    public func load(_ deck: Int, _ track: OpaquePointer?) { be_deck_load(raw, Int32(deck), track) }
    public func play(_ deck: Int, trackBeat: Double = .nan) { be_play(raw, Int32(deck), trackBeat) }
    public func stop(_ deck: Int) { be_stop(raw, Int32(deck)) }
    public func cue(_ deck: Int, trackBeat: Double) { be_cue(raw, Int32(deck), trackBeat) }
    public func cancel(tag: Int) { be_cancel(raw, Int32(tag)) }
    public func set(_ deck: Int, _ param: Int32, _ value: Float) { be_set_param(raw, Int32(deck), param, value) }
    public func setTempo(_ bpm: Double) { be_set_tempo(raw, bpm) }
    public func scratchBegin(_ deck: Int) { be_scratch_begin(raw, Int32(deck)) }
    public func scratchMove(_ deck: Int, frames: Double) { be_scratch_move(raw, Int32(deck), frames) }
    public func scratchEnd(_ deck: Int) { be_scratch_end(raw, Int32(deck)) }
    public func syncPhase(_ deck: Int) { be_sync_phase(raw, Int32(deck)) }
    public func reset() { be_reset(raw) }
    public func setOutputEffect(_ preset: Int32) { be_set_master_fx(raw, preset) }
    public func loadVoice(_ clip: OpaquePointer?) { be_voice_load(raw, clip) }

    public func event(_ type: Int32, deck: Int, at beat: Double, value: Double = 0, from: Double = .nan, tag: Int = 0) {
        var ev = be_event(type: type, deck: Int32(deck), param: 0, tag: Int32(tag), curve: 0, beat: beat, endBeat: beat, value: value, from: from)
        be_schedule(raw, &ev)
    }

    public func ramp(deck: Int, _ param: Int32, to value: Double, from: Double = .nan, start: Double, end: Double, curve: Curve = .linear, tag: Int = 0) {
        var ev = be_event(type: Int32(BE_EV_RAMP), deck: Int32(deck), param: param, tag: Int32(tag), curve: curve.rawValue, beat: start, endBeat: end, value: value, from: from)
        be_schedule(raw, &ev)
    }

    public func start(_ deck: Int, at beat: Double, trackBeat: Double, tag: Int = 0) { event(Int32(BE_EV_START), deck: deck, at: beat, value: trackBeat, tag: tag) }
    public func stop(_ deck: Int, at beat: Double, tag: Int = 0) { event(Int32(BE_EV_STOP), deck: deck, at: beat, tag: tag) }
    public func seek(_ deck: Int, at beat: Double, trackBeat: Double, tag: Int = 0) { event(Int32(BE_EV_SEEK), deck: deck, at: beat, value: trackBeat, tag: tag) }
    public func tempoRamp(to bpm: Double, start: Double, end: Double, tag: Int = 0) { ramp(deck: -1, Int32(BE_P_TEMPO), to: bpm, start: start, end: end, tag: tag) }
}
