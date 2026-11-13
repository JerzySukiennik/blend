// Blend kit: the live session. Queue, two decks, automix planning and the eight moves, all scheduled on the engine's beat clock.
import BlendEngine
import Foundation
import Observation

public extension be_state {
    func deck(_ i: Int) -> be_deck_state { i == 0 ? deck.0 : deck.1 }
}

public extension be_deck_state {
    func param(_ i: Int32) -> Float { withUnsafeBytes(of: params) { $0.load(fromByteOffset: Int(i) * 4, as: Float.self) } }
    func stemLevel(_ i: Int) -> Float { withUnsafeBytes(of: level) { $0.load(fromByteOffset: i * 4, as: Float.self) } }
}

@Observable
public final class Session {
    public struct DeckModel {
        public var track: LoadedTrack?
        public var loading: TrackInfo?
        public var stemOn = [true, true, true, true]
        public var pitch = 0
    }

    public enum Mash: String {
        case vocal, beat
    }

    @ObservationIgnored public let engine: Engine
    public private(set) var library: [TrackInfo] = []
    public private(set) var analyses: [String: Analysis] = [:]
    public private(set) var queue: [TrackInfo] = []
    public private(set) var decks = [DeckModel(), DeckModel()]
    public private(set) var current: Int?
    public private(set) var paused = false
    public private(set) var transition: Transition?
    public private(set) var mash: Mash?
    public private(set) var countdownBars: Int?
    public private(set) var hint: String?
    public private(set) var flash: Move?
    public private(set) var flashCount = 0
    public private(set) var analyzing: String?
    public private(set) var mixProgress: Double?
    public private(set) var looping = false
    public private(set) var filter: [Float] = [0, 0]
    public var autoMix = true

    @ObservationIgnored public var loader: (TrackInfo, @escaping (Result<LoadedTrack, Error>) -> Void) -> Void = { info, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LoadedTrack.load(info) }
            DispatchQueue.main.async { done(result) }
        }
    }
    @ObservationIgnored public var log: ((String) -> Void)?
    @ObservationIgnored private var unloadAt: [Double?] = [nil, nil]
    @ObservationIgnored private var scratching = [false, false]
    @ObservationIgnored private var tagCounter = 100
    @ObservationIgnored private var hintUntil = Date.distantPast
    @ObservationIgnored private var plan: Transition?
    @ObservationIgnored private var planKey = ""
    @ObservationIgnored private var planEpoch = 0
    @ObservationIgnored private var busyUntil = -Double.infinity
    @ObservationIgnored private var pauseAfterBrake = false
    @ObservationIgnored private var awaitingStart = false
    @ObservationIgnored private var loopStart = [0.0, 0.0]
    @ObservationIgnored private var loopLen = [4.0, 4.0]

    public init(engine: Engine = Engine()) {
        self.engine = engine
    }

    public var nextDeck: Int? {
        guard let c = current, decks[1 - c].track != nil, unloadAt[1 - c] == nil else { return nil }
        return 1 - c
    }

    public var cuedDeck: Int? { current == nil ? decks.firstIndex { $0.track != nil } : nil }
    public var isBusy: Bool { transition != nil || mash != nil }

    public func reloadLibrary() {
        library = Library.scan()
        var found: [String: Analysis] = [:]
        for info in library {
            if let a = LoadedTrack.cachedAnalysis(info) { found[info.id] = a }
        }
        analyses = found
    }

    public func analyzeMissing() {
        let missing = library.filter { analyses[$0.id] == nil }
        guard !missing.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            for info in missing {
                DispatchQueue.main.async { self?.analyzing = info.title }
                let loaded = try? LoadedTrack.load(info)
                DispatchQueue.main.async {
                    if let loaded { self?.analyses[info.id] = loaded.analysis }
                }
            }
            DispatchQueue.main.async { self?.analyzing = nil }
        }
    }

    public func importFiles(_ urls: [URL]) async {
        var added: [TrackInfo] = []
        for url in urls {
            if let info = await Library.importFile(url) { added.append(info) }
        }
        let failed = added.isEmpty
        await MainActor.run {
            self.reloadLibrary()
            self.analyzeMissing()
            if failed { self.say("That file is not audio Blend can read") }
        }
    }

    public func removeFromLibrary(_ info: TrackInfo) {
        guard decks.allSatisfy({ $0.track?.info.id != info.id && $0.loading?.id != info.id }) else {
            say("That song is on a deck")
            return
        }
        queue.removeAll { $0.id == info.id }
        Library.remove(info)
        reloadLibrary()
    }

    public func enqueue(_ info: TrackInfo) {
        guard !queue.contains(where: { $0.id == info.id }) else { return }
        queue.append(info)
        refill()
    }

    public func dequeue(_ info: TrackInfo) {
        if isBusy, let n = nextDeck, decks[n].track?.info.id == info.id {
            say("That song is mixing in right now")
            return
        }
        queue.removeAll { $0.id == info.id }
        refill()
    }

    public func moveInQueue(from: Int, to: Int) {
        guard queue.indices.contains(from), to >= 0, to < queue.count, from != to else { return }
        if isBusy, from == 0 || to == 0 { return }
        let item = queue.remove(at: from)
        queue.insert(item, at: to)
        refill()
    }

    public func fit(_ info: TrackInfo) -> Int {
        guard let c = current, let a = decks[c].track, let b = analyses[info.id] else { return 0 }
        let ratio = b.bpm / a.analysis.bpm
        let tempo = abs(ratio - 1) < 0.035 ? 2 : abs(ratio - 1) < 0.08 ? 1 : 0
        let key = Key.match(effectiveKey(c), b.key).score
        if tempo == 2 && key >= 2 { return 3 }
        if tempo >= 1 && key >= 1 { return 2 }
        return tempo >= 1 ? 1 : 0
    }

    private func effectiveKey(_ deck: Int) -> Int {
        guard let t = decks[deck].track else { return 0 }
        let k = t.analysis.key
        return ((k % 12 + decks[deck].pitch) % 12 + 12) % 12 + (k >= 12 ? 12 : 0)
    }

    private func say(_ text: String) {
        hint = text
        hintUntil = Date().addingTimeInterval(2.6)
        log?("hint: \(text)")
    }

    private func nextTag() -> Int {
        tagCounter += 1
        return tagCounter
    }

    private func refill() {
        if isBusy { return }
        let target: Int
        if let c = current {
            target = 1 - c
        } else {
            target = (decks[1].track != nil || decks[1].loading != nil) && decks[0].track == nil && decks[0].loading == nil ? 1 : 0
        }
        if unloadAt[target] != nil { return }
        let want = queue.first
        if let have = decks[target].track?.info ?? decks[target].loading {
            if have.id == want?.id { return }
            engine.load(target, nil)
            decks[target] = DeckModel()
            plan = nil
        }
        guard let want else { return }
        decks[target].loading = want
        loader(want) { [weak self] result in
            guard let self, self.decks[target].loading?.id == want.id else { return }
            switch result {
            case .success(let track):
                var model = DeckModel()
                model.track = track
                self.decks[target] = model
                self.engine.load(target, track.raw)
                self.analyses[want.id] = track.analysis
                self.log?("loaded \(track.info.title) on deck \(target)")
            case .failure(let error):
                self.decks[target].loading = nil
                self.queue.removeAll { $0.id == want.id }
                self.say(error.localizedDescription)
                self.refill()
            }
        }
    }

    private func startFirst(_ d: Int) {
        guard let t = decks[d].track else { return }
        let st = t.structure
        let tb = st.firstSound > 0 ? st.beat(ofBar: st.startBar) : -t.analysis.firstBeatFrame / t.fpb
        for s in Stem.allCases { engine.set(d, s.param, 1) }
        engine.set(d, Int32(BE_P_VOLUME), 1)
        engine.set(d, Int32(BE_P_FILTER), 0)
        engine.play(d, trackBeat: tb)
        awaitingStart = true
        current = d
        paused = false
        if let i = queue.firstIndex(where: { $0.id == t.info.id }) { queue.remove(at: i) }
        plan = nil
        log?("play \(t.info.title) from beat \(tb)")
        refill()
    }

    public func playPause(_ deck: Int) {
        guard let c = current else {
            if cuedDeck == deck { startFirst(deck) }
            return
        }
        if deck != c {
            if nextDeck == deck { mix() }
            return
        }
        if paused {
            engine.play(c)
            awaitingStart = true
            paused = false
            planEpoch += 1
        } else if isBusy {
            say("Finish the mix first")
        } else {
            engine.stop(c)
            paused = true
            plan = nil
        }
    }

    public func toggleStem(_ deck: Int, _ stem: Stem) {
        guard decks[deck].track != nil else { return }
        decks[deck].stemOn[stem.rawValue].toggle()
        engine.set(deck, Int32(BE_P_USER0) + Int32(stem.rawValue), decks[deck].stemOn[stem.rawValue] ? 1 : 0)
    }

    public func setFilter(_ deck: Int, _ value: Float) {
        let v = max(-1, min(1, value))
        engine.set(deck, Int32(BE_P_FILTER), v)
        let shown = (v * 40).rounded() / 40
        if filter[deck] != shown { filter[deck] = shown }
    }

    public func scratchBegin(_ deck: Int) {
        guard decks[deck].track != nil else { return }
        scratching[deck] = true
        engine.scratchBegin(deck)
    }

    public func scratchMove(_ deck: Int, frames: Double) {
        if scratching[deck] { engine.scratchMove(deck, frames: frames) }
    }

    public func scratchEnd(_ deck: Int) {
        guard scratching[deck] else { return }
        scratching[deck] = false
        engine.scratchEnd(deck)
        planEpoch += 1
    }

    public func sync(_ deck: Int) {
        engine.syncPhase(deck)
        planEpoch += 1
    }

    public func perform(_ move: Move) {
        flash = move
        flashCount += 1
        switch move {
        case .mix: mix()
        case .vocal: toggleMash(.vocal)
        case .beat: toggleMash(.beat)
        case .build: cut(.build)
        case .echo: cut(.echo)
        case .brake: cut(.brake)
        case .drop: dropJump()
        case .loop: toggleLoop()
        }
    }

    public func mix() {
        guard let c = current else {
            if let d = cuedDeck {
                startFirst(d)
            } else {
                say(queue.isEmpty ? "Add a song to the queue first" : "Loading the song")
            }
            return
        }
        if paused {
            playPause(c)
            return
        }
        if var tr = transition {
            if tr.manual, tr.style == .blend { resumeAuto(&tr) }
            return
        }
        guard let n = nextDeck else {
            say(queue.isEmpty ? "Queue a song to mix into" : "Next song is still loading")
            return
        }
        guard var tr = planBlend(from: c, to: n, auto: false, engine.state) else { return }
        if tr.style == .blend {
            commit(&tr)
        } else {
            cut(.echo, lead: 4)
        }
    }

    private func nextBar(_ st: Structure, after beat: Double, ahead: Double, every: Int) -> Int {
        var b = st.bar(atBeat: beat + ahead) + 1
        while !st.isPhrase(b, every: every) { b += 1 }
        return b
    }

    private func planBlend(from f: Int, to t: Int, auto: Bool, _ s: be_state) -> Transition? {
        guard let a = decks[f].track, let b = decks[t].track else { return nil }
        let sa = a.structure, sb = b.structure
        let da = s.deck(f), db = s.deck(t)
        let toPlaying = db.playing != 0
        let ratio = b.analysis.bpm / s.masterBpm
        var n = auto ? 16 : 8
        if toPlaying {
            n = 8
        } else {
            let intro = sb.firstFull - sb.startBar
            if intro >= 8 {
                while n > intro { n /= 2 }
            } else {
                n = min(n, 8)
            }
            if a.analysis.confidence < 0.6 || b.analysis.confidence < 0.6 { n = min(n, 4) }
        }
        let endBar = sa.lastStrong + 1
        var startBar: Int
        if auto {
            startBar = sa.phraseStart(atOrBefore: endBar - n, every: 4)
            if sa.beat(ofBar: startBar) < da.beat + 1 { startBar = nextBar(sa, after: da.beat, ahead: 1, every: 4) }
        } else {
            startBar = nextBar(sa, after: da.beat, ahead: 1, every: mash != nil ? 2 : 4)
        }
        let left = max(2, endBar - startBar)
        while n > 2 && n > left { n /= 2 }
        let bStartBar = toPlaying ? 0 : sb.startBar
        let length = Double(n * 4)
        var tr = Transition(style: .blend, from: f, to: t, startBeat: sa.beat(ofBar: startBar) - da.offset, length: length, toTrackBeat: sb.beat(ofBar: bStartBar),
                            tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: nextTag())
        tr.toWasPlaying = toPlaying
        if !toPlaying && (ratio > 1.11 || ratio < 0.9) {
            tr.style = .echo
            return tr
        }
        let keyed = Key.match(effectiveKey(f), toPlaying ? effectiveKey(t) : b.analysis.key)
        let sure = toPlaying || min(a.analysis.keyStrength, b.analysis.keyStrength) >= 0.05
        tr.clash = !sure || keyed.score == 0 || abs(keyed.shift) > 1 || (toPlaying && keyed.shift != 0)
        tr.pitch = tr.clash || toPlaying ? 0 : keyed.shift
        tr.lanes = Lanes.blend(from: f, to: t, fromStems: a.stems == 4, toStems: b.stems == 4, toDrums: sb.stemPresent[Stem.drums.rawValue], clash: tr.clash, toPlaying: toPlaying, beat: 1 / length) { deck, param in
            Double(s.deck(deck).param(param))
        }
        log?("plan blend \(a.info.title) bar \(startBar) -> \(b.info.title) bar \(bStartBar), \(n) bars, clash \(tr.clash), key shift \(tr.pitch), tempo \(tr.tempoFrom) -> \(tr.tempoTo)")
        return tr
    }

    private func tune(_ deck: Int, _ semitones: Int, tag: Int) {
        decks[deck].pitch = semitones
        engine.event(Int32(BE_EV_PITCH), deck: deck, at: .nan, value: Double(semitones), tag: tag)
    }

    public func keyText(_ deck: Int) -> String {
        guard let t = decks[deck].track else { return "" }
        let shift = decks[deck].pitch
        return shift == 0 ? t.analysis.keyName : Key.name(effectiveKey(deck)) + (shift > 0 ? " +\(shift)" : " \(shift)")
    }

    private func commit(_ tr: inout Transition) {
        for lane in tr.lanes where lane.applyBase { engine.set(lane.deck, lane.param, Float(lane.base)) }
        if !tr.toWasPlaying {
            tune(tr.to, tr.pitch, tag: tr.tag)
            for s in 0..<4 { engine.set(tr.to, Int32(BE_P_USER0) + Int32(s), decks[tr.to].stemOn[s] ? 1 : 0) }
            engine.start(tr.to, at: tr.startBeat, trackBeat: tr.toTrackBeat, tag: tr.tag)
        }
        schedule(tr, from: 0, start: tr.startBeat, length: tr.length)
        tr.committed = true
        tr.manual = false
        transition = tr
        plan = nil
        log?("commit \(tr.style.rawValue) start \(tr.startBeat) length \(tr.length)")
    }

    private func schedule(_ tr: Transition, from p0: Double, start: Double, length: Double) {
        let span = max(1e-6, 1 - p0)
        for lane in tr.lanes {
            for seg in lane.segs where seg.p1 > p0 {
                let a = max(seg.p0, p0)
                engine.ramp(deck: lane.deck, lane.param, to: seg.v, start: start + (a - p0) / span * length, end: start + (seg.p1 - p0) / span * length, tag: tr.tag)
            }
        }
        if abs(tr.tempoTo - tr.tempoFrom) > 1e-6 { engine.tempoRamp(to: tr.tempoTo, start: start, end: start + length, tag: tr.tag) }
        engine.stop(tr.from, at: start + length, tag: tr.tag)
    }

    private func applyManual(_ tr: Transition) {
        for lane in tr.lanes { engine.set(lane.deck, lane.param, Float(lane.value(at: tr.progress))) }
        engine.setTempo(tr.tempoFrom + (tr.tempoTo - tr.tempoFrom) * tr.progress)
    }

    private func resumeAuto(_ tr: inout Transition) {
        let s = engine.state
        let remaining = max(4, ((1 - tr.progress) * tr.length / 4).rounded(.up) * 4)
        let start = s.masterBeat + 0.25
        tr.tag = nextTag()
        schedule(tr, from: tr.progress, start: start, length: remaining)
        let p = tr.progress
        tr.startBeat = start - p / max(1e-6, 1 - p) * remaining
        tr.length = remaining / max(1e-6, 1 - p)
        tr.manual = false
        transition = tr
    }

    public func crossfade(delta: Double) {
        guard let c = current, !paused else { return }
        let s = engine.state
        if transition == nil {
            guard mash == nil, let n = nextDeck, var tr = planBlend(from: c, to: n, auto: false, s), tr.style == .blend, let a = decks[c].track else { return }
            let bar = nextBar(a.structure, after: s.deck(c).beat, ahead: 0.25, every: 1)
            tr.startBeat = a.structure.beat(ofBar: bar) - s.deck(c).offset
            tr.manual = true
            tr.committed = true
            for lane in tr.lanes where lane.applyBase { engine.set(lane.deck, lane.param, Float(lane.base)) }
            tune(tr.to, tr.pitch, tag: tr.tag)
            for st in 0..<4 { engine.set(tr.to, Int32(BE_P_USER0) + Int32(st), decks[tr.to].stemOn[st] ? 1 : 0) }
            engine.start(tr.to, at: tr.startBeat, trackBeat: tr.toTrackBeat, tag: tr.tag)
            transition = tr
            plan = nil
        }
        guard var tr = transition, tr.style == .blend else { return }
        if !tr.manual {
            tr.progress = tr.progress(atBeat: s.masterBeat)
            engine.cancel(tag: tr.tag)
            tr.manual = true
        }
        tr.progress = min(1, max(0, tr.progress + delta * (tr.to == 1 ? 1 : -1)))
        applyManual(tr)
        transition = tr
    }

    public func crossfadeEnd() {
        guard let tr = transition, tr.manual else { return }
        let s = engine.state
        if tr.progress >= 0.985 {
            var done = tr
            done.progress = 1
            applyManual(done)
            engine.stop(tr.from)
            finish(done, beat: s.masterBeat)
        } else if tr.progress <= 0.015 {
            var back = tr
            back.progress = 0
            applyManual(back)
            engine.stop(tr.to)
            if !tr.toWasPlaying { tune(tr.to, 0, tag: nextTag()) }
            transition = nil
            planEpoch += 1
        }
    }

    private func finish(_ tr: Transition, beat: Double) {
        transition = nil
        mash = nil
        current = tr.to
        if let id = decks[tr.to].track?.info.id, let i = queue.firstIndex(where: { $0.id == id }) { queue.remove(at: i) }
        unloadAt[tr.from] = beat + (tr.style == .echo ? 16 : tr.style == .blend ? 12 : 4)
        countdownBars = nil
        plan = nil
        planEpoch += 1
        log?("finished \(tr.style.rawValue) at beat \(beat), now deck \(tr.to)")
    }

    private func toggleMash(_ kind: Mash) {
        guard let c = current, !paused else { return }
        guard transition == nil else {
            say("Wait for the mix to finish")
            return
        }
        let s = engine.state
        guard let n = nextDeck, let a = decks[c].track, let b = decks[n].track else {
            say(queue.isEmpty ? "Queue a song for the mashup" : "Next song is still loading")
            return
        }
        let sa = a.structure, sb = b.structure, da = s.deck(c)
        if let active = mash {
            let bar = nextBar(sa, after: da.beat, ahead: 0.5, every: 1)
            let at = sa.beat(ofBar: bar) - da.offset
            let tag = nextTag()
            if active == .vocal {
                engine.ramp(deck: c, Stem.vocals.param, to: 1, start: at, end: at + 0.5, tag: tag)
                engine.ramp(deck: n, Stem.vocals.param, to: 0, start: at - 0.5, end: at, tag: tag)
            } else {
                for st in [Stem.drums, .bass, .music] { engine.ramp(deck: c, st.param, to: 1, start: at - 0.06, end: at, tag: tag) }
            }
            engine.stop(n, at: at, tag: tag)
            engine.event(Int32(BE_EV_PITCH), deck: n, at: at + 0.05, value: 0, tag: tag)
            decks[n].pitch = 0
            mash = nil
            busyUntil = at + 1
            planEpoch += 1
            return
        }
        guard a.stems == 4, b.stems == 4 else {
            say("Mashups need stems on both songs")
            return
        }
        var bBar = sb.firstFull
        if kind == .vocal {
            guard let v = sb.vocalStarts.first(where: { $0 >= max(0, sb.firstFull - 8) }) ?? sb.vocalStarts.first else {
                say("The next song has no vocal")
                return
            }
            bBar = sb.phraseStart(atOrBefore: v, every: 4)
        }
        let ahead = nextBar(sa, after: da.beat, ahead: 1, every: 4)
        let near = nextBar(sa, after: da.beat, ahead: 1, every: 1)
        let bar = sa.beat(ofBar: ahead) - da.beat <= 9 ? ahead : near
        let at = sa.beat(ofBar: bar) - da.offset
        let tag = nextTag()
        let match = Key.match(effectiveKey(c), b.analysis.key)
        let shift = match.score > 0 ? match.shift : 0
        decks[n].pitch = shift
        engine.event(Int32(BE_EV_PITCH), deck: n, at: .nan, value: Double(shift), tag: tag)
        for st in Stem.allCases { engine.set(n, st.param, 0) }
        for st in 0..<4 { engine.set(n, Int32(BE_P_USER0) + Int32(st), decks[n].stemOn[st] ? 1 : 0) }
        engine.set(n, Int32(BE_P_VOLUME), 1)
        engine.set(n, Int32(BE_P_FILTER), 0)
        engine.start(n, at: at, trackBeat: sb.beat(ofBar: bBar), tag: tag)
        if kind == .vocal {
            engine.ramp(deck: n, Stem.vocals.param, to: 1, start: at, end: at + 0.5, tag: tag)
            engine.ramp(deck: c, Stem.vocals.param, to: 0, start: at - 1, end: at, tag: tag)
        } else {
            let swapped: [Stem] = sa.stemPresent[Stem.vocals.rawValue] ? [.drums, .bass, .music] : [.drums, .bass]
            for st in swapped {
                engine.ramp(deck: n, st.param, to: 1, start: at, end: at + 0.06, tag: tag)
                engine.ramp(deck: c, st.param, to: 0, start: at - 0.12, end: at, tag: tag)
            }
        }
        mash = kind
        plan = nil
        log?("mash \(kind.rawValue) at beat \(at): \(b.info.title) bar \(bBar), shift \(shift)")
    }

    private func dropBeat(_ t: LoadedTrack) -> Double {
        t.structure.beat(ofBar: t.structure.drops.first ?? t.structure.firstFull)
    }

    private func fullBeat(_ t: LoadedTrack) -> Double { t.structure.beat(ofBar: t.structure.firstFull) }
    private func startBeat(_ t: LoadedTrack) -> Double { t.structure.beat(ofBar: t.structure.startBar) }

    private func prepareFull(_ deck: Int) {
        for st in Stem.allCases { engine.set(deck, st.param, 1) }
        for st in 0..<4 { engine.set(deck, Int32(BE_P_USER0) + Int32(st), decks[deck].stemOn[st] ? 1 : 0) }
        engine.set(deck, Int32(BE_P_VOLUME), 1)
        engine.set(deck, Int32(BE_P_FILTER), 0)
        engine.set(deck, Int32(BE_P_ECHO), 0)
    }

    private func cut(_ style: Transition.Style, lead: Double = 0) {
        guard let c = current, !paused, let a = decks[c].track else { return }
        guard transition == nil else {
            say("Wait for the mix to finish")
            return
        }
        guard mash == nil else {
            say("Turn the mashup off first")
            return
        }
        let s = engine.state, sa = a.structure, da = s.deck(c)
        let n = nextDeck, b = n.flatMap { decks[$0].track }
        let tag = nextTag()
        let filter = Int32(BE_P_FILTER), echo = Int32(BE_P_ECHO), volume = Int32(BE_P_VOLUME)
        var tr: Transition?
        switch style {
        case .build:
            let start = sa.beat(ofBar: nextBar(sa, after: da.beat, ahead: 0.5, every: 1)) - da.offset, end = start + 16
            engine.ramp(deck: c, filter, to: 0.72, start: start, end: end, curve: .easeIn, tag: tag)
            for (before, len) in [(8.0, 1.0), (4.0, 0.5), (2.0, 0.25), (1.0, 0.125)] { engine.event(Int32(BE_EV_ROLL), deck: c, at: end - before, value: len, tag: tag) }
            engine.event(Int32(BE_EV_UNROLL), deck: c, at: end, tag: tag)
            if let n, let b {
                prepareFull(n)
                engine.start(n, at: end, trackBeat: dropBeat(b), tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                engine.stop(c, at: end, tag: tag)
                tr = Transition(style: .build, from: c, to: n, startBeat: start, length: 16, toTrackBeat: dropBeat(b), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
            } else {
                engine.ramp(deck: c, filter, to: 0, start: end, end: end + 0.03, tag: tag)
                busyUntil = end + 1
            }
        case .echo:
            let washed = lead > 0 && n != nil && b != nil
            let end = sa.beat(ofBar: nextBar(sa, after: da.beat, ahead: 1.5 + (washed ? lead : 0), every: 1)) - da.offset
            if washed {
                engine.ramp(deck: c, filter, to: 0.62, start: end - lead, end: end - 0.5, curve: .easeIn, tag: tag)
                engine.ramp(deck: c, echo, to: 0.85, start: end - min(lead, 3), end: end - 0.5, tag: tag)
            } else {
                engine.ramp(deck: c, echo, to: 1, start: end - 1, end: end - 0.5, tag: tag)
            }
            if let n, let b {
                prepareFull(n)
                engine.ramp(deck: c, volume, to: 0, start: end - 0.08, end: end, tag: tag)
                engine.ramp(deck: c, echo, to: 0, start: end, end: end + 0.05, tag: tag)
                engine.start(n, at: end, trackBeat: startBeat(b), tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                engine.stop(c, at: end + 0.1, tag: tag)
                let span = washed ? lead : 1
                tr = Transition(style: .echo, from: c, to: n, startBeat: end - span, length: span, toTrackBeat: startBeat(b), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
            } else {
                engine.ramp(deck: c, echo, to: 0, start: end, end: end + 0.1, tag: tag)
            }
        case .brake:
            let end = sa.beat(ofBar: nextBar(sa, after: da.beat, ahead: 2, every: 1)) - da.offset
            engine.event(Int32(BE_EV_BRAKE), deck: c, at: end - 1, value: 1, tag: tag)
            if let n, let b {
                prepareFull(n)
                engine.start(n, at: end, trackBeat: startBeat(b), tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                tr = Transition(style: .brake, from: c, to: n, startBeat: end - 1, length: 1, toTrackBeat: startBeat(b), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
            } else {
                pauseAfterBrake = true
            }
        case .blend:
            break
        }
        if var tr {
            tr.committed = true
            transition = tr
            plan = nil
            log?("commit \(style.rawValue) start \(tr.startBeat) end \(tr.endBeat)")
        }
    }

    private func dropJump() {
        guard let c = current, !paused, transition == nil, let a = decks[c].track else { return }
        let s = engine.state, sa = a.structure, da = s.deck(c)
        let here = sa.bar(atBeat: da.beat)
        guard let target = sa.nextDrop(afterBar: here) else {
            say("No drop found in this song")
            return
        }
        let bar = nextBar(sa, after: da.beat, ahead: 0.5, every: 1)
        engine.seek(c, at: sa.beat(ofBar: bar) - da.offset, trackBeat: sa.beat(ofBar: target), tag: nextTag())
        busyUntil = sa.beat(ofBar: bar) - da.offset + 1
        planEpoch += 1
        plan = nil
    }

    private func toggleLoop() {
        guard let c = current, !paused, decks[c].track != nil else { return }
        let s = engine.state, da = s.deck(c)
        if da.looping != 0 {
            engine.event(Int32(BE_EV_UNLOOP), deck: c, at: .nan)
            planEpoch += 1
            plan = nil
            return
        }
        guard transition == nil else {
            say("Wait for the mix to finish")
            return
        }
        let from = (da.beat - 0.02).rounded(.up)
        loopStart[c] = from
        loopLen[c] = 4
        engine.event(Int32(BE_EV_LOOP), deck: c, at: from - da.offset, value: 4, from: from)
        plan = nil
    }

    public func scaleLoop(_ factor: Double) {
        guard let c = current else { return }
        let da = engine.state.deck(c)
        guard da.looping != 0 else { return }
        loopLen[c] = min(16, max(0.125, loopLen[c] * factor))
        engine.event(Int32(BE_EV_LOOP), deck: c, at: .nan, value: loopLen[c], from: loopStart[c])
    }

    public func tick() {
        let s = engine.state
        engine.collect()
        let beat = s.masterBeat
        if hint != nil, Date() > hintUntil { hint = nil }
        let loopNow = current.map { s.deck($0).looping != 0 } ?? false
        if loopNow != looping { looping = loopNow }
        if let tr = transition {
            let p = tr.progress(atBeat: beat)
            if mixProgress == nil || abs(p - (mixProgress ?? 0)) > 0.012 || (p >= 1 && mixProgress != 1) { mixProgress = p }
        } else if mixProgress != nil {
            mixProgress = nil
        }
        for d in 0..<2 {
            guard let at = unloadAt[d], beat >= at || current == nil else { continue }
            engine.load(d, nil)
            decks[d] = DeckModel()
            unloadAt[d] = nil
            refill()
        }
        guard let c = current else {
            if countdownBars != nil { countdownBars = nil }
            return
        }
        if let tr = transition {
            let left = Int(((tr.startBeat - beat) / 4).rounded(.up))
            let shown: Int? = tr.manual ? nil : max(0, left)
            if countdownBars != shown { countdownBars = shown }
            if !tr.manual, beat >= tr.endBeat + (tr.style == .echo ? 0.15 : 0) { finish(tr, beat: beat) }
            return
        }
        let dc = s.deck(c)
        if awaitingStart {
            if dc.playing == 0 { return }
            awaitingStart = false
        }
        if pauseAfterBrake, dc.playing == 0 {
            pauseAfterBrake = false
            paused = true
        }
        if dc.ended != 0 || (dc.playing == 0 && !paused && !pauseAfterBrake && !scratching[c]) {
            log?("deck \(c) ended")
            engine.load(c, nil)
            decks[c] = DeckModel()
            current = nil
            mash = nil
            plan = nil
            countdownBars = nil
            refill()
            if autoMix, let d = cuedDeck { startFirst(d) }
            return
        }
        guard autoMix, mash == nil, !paused, dc.looping == 0, !scratching[c], beat >= busyUntil, let n = nextDeck, let a = decks[c].track, let b = decks[n].track else {
            if countdownBars != nil { countdownBars = nil }
            return
        }
        let key = "\(a.info.id)|\(b.info.id)|\(s.epoch)|\(planEpoch)"
        if plan == nil || planKey != key {
            plan = planBlend(from: c, to: n, auto: true, s)
            planKey = key
        }
        guard var p = plan else { return }
        let left = p.startBeat - beat
        let shown = max(0, Int((left / 4).rounded(.up)))
        if countdownBars != shown { countdownBars = shown }
        if p.style == .echo {
            if left < 21.4, left > 17.6 {
                cut(.echo, lead: 16)
            } else if left < 13.4, left > 9.6 {
                cut(.echo, lead: 8)
            } else if left < 6, left > 2.2 {
                cut(.echo)
            } else if left <= 0.5 {
                plan = nil
            }
        } else if left < 6 {
            if left > 0.5 {
                commit(&p)
            } else {
                plan = nil
            }
        }
    }
}
