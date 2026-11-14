// Blend kit: the live session. Queue, two decks, automix planning, transition techniques and the moves, all scheduled on the engine's beat clock.
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
    public private(set) var rolling = false
    public private(set) var upcoming: Technique?
    public private(set) var style: Technique?
    public private(set) var effect: Effect?
    public private(set) var speeches: [Speech] = []
    public private(set) var speaking: Speech?
    public private(set) var beatInBar = -1
    public var autoMix = true

    @ObservationIgnored public var loader: (TrackInfo, @escaping (Result<LoadedTrack, Error>) -> Void) -> Void = { info, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try LoadedTrack.load(info) }
            DispatchQueue.main.async { done(result) }
        }
    }
    @ObservationIgnored public var log: ((String) -> Void)?
    @ObservationIgnored public var voiceGain = 1.3
    @ObservationIgnored public var voiceLoader: (Speech, ClosedRange<Double>?, @escaping (OpaquePointer?) -> Void) -> Void = { speech, range, done in
        DispatchQueue.global(qos: .userInitiated).async {
            let clip = Speeches.load(speech, range: range)
            DispatchQueue.main.async { done(clip) }
        }
    }
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
    @ObservationIgnored private var used: [Technique: Int] = [:]
    @ObservationIgnored private var useCount = 0
    @ObservationIgnored private var bridgeRun = 0
    @ObservationIgnored private var voiceBag: [Speech] = []
    @ObservationIgnored private var voiceFrom = 0.0
    @ObservationIgnored private var voiceHeard = false
    @ObservationIgnored private var voiceTag = 0
    @ObservationIgnored private var rollDeck: Int?
    @ObservationIgnored private var rollTag = 0
    @ObservationIgnored private var rollLen = 0.5

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
        guard !missing.isEmpty, analyzing == nil else { return }
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

    public var mixReference: TrackInfo? { queue.last ?? current.flatMap { decks[$0].track?.info } }

    public func fit(_ info: TrackInfo, to ref: TrackInfo? = nil) -> Int {
        guard let ref = ref ?? mixReference, ref.id != info.id, let a = analyses[ref.id], let b = analyses[info.id] else { return 0 }
        if ref.twin?.of == info.id || info.twin?.of == ref.id { return 3 }
        var key = a.key
        if let c = current, decks[c].track?.info.id == ref.id { key = effectiveKey(c) }
        let ratio = b.bpm / a.bpm
        if ratio > 1.22 || ratio < 0.82 { return 0 }
        let match = Key.match(key, b.key)
        let harmonic = min(a.keyStrength, b.keyStrength) >= 0.05 && match.score >= 2 && abs(match.shift) <= 1
        guard harmonic, ratio <= 1.11, ratio >= 0.9 else { return 1 }
        return abs(ratio - 1) < 0.045 && match.shift == 0 ? 3 : 2
    }

    public func cycleStyle(_ step: Int = 1) {
        let all: [Technique?] = [nil] + Technique.allCases.map { $0 }
        let i = all.firstIndex { $0 == style } ?? 0
        style = all[((i + step) % all.count + all.count) % all.count]
        plan = nil
        planEpoch += 1
        say(style.map { "\($0.label): \($0.help)" } ?? "AUTO: Blend picks the mix style")
    }

    public func reloadSpeeches() { speeches = Speeches.scan() }

    private func voiceMarks(_ s: be_state) -> (big: [Double], small: [Double]) {
        guard let c = current, let a = decks[c].track else { return ([], []) }
        let sa = a.structure, da = s.deck(c)
        var big: [Double] = [], small: [Double] = []
        if let tr = transition ?? plan {
            var share = 1.0
            if tr.style == .blend {
                share = 0.5
                if tr.technique == .ride || tr.technique == .bridge { share = 0.75 }
                if tr.technique == .loop || tr.technique == .chop { share = 1 }
            }
            big.append(tr.startBeat + share * tr.length)
        }
        let here = sa.bar(atBeat: da.beat)
        if let drop = sa.drops.first(where: { $0 > here }) { big.append(sa.beat(ofBar: drop) - da.offset) }
        var bar = here + 1
        while small.count < 10, bar < sa.bars {
            if sa.isPhrase(bar, every: 4) { small.append(sa.beat(ofBar: bar) - da.offset) }
            bar += 1
        }
        return (big.filter { $0 > s.masterBeat }.sorted(), small.filter { $0 > s.masterBeat })
    }

    private func voiceFit(_ clip: Speech, _ marks: (big: [Double], small: [Double]), now: Double, bps: Double) -> (start: Double, mark: Double, cost: Double)? {
        var best: (start: Double, mark: Double, cost: Double)?
        for (list, reach, cost) in [(marks.big, 16.0, 0.0), (marks.small, 8.0, 8.0)] {
            for mark in list {
                let wait = mark - clip.hit * bps - now
                guard wait >= 0.75, wait <= reach, wait + cost < (best?.cost ?? .infinity) else { continue }
                best = (now + wait, mark, wait + cost)
            }
        }
        return best
    }

    public func speak(_ wanted: Speech? = nil) {
        if let old = speaking {
            engine.cancel(tag: voiceTag)
            engine.event(Int32(BE_EV_VOICE_STOP), deck: -1, at: .nan)
            speaking = nil
            if wanted == nil || wanted?.id == old.id { return }
        }
        if voiceBag.isEmpty {
            reloadSpeeches()
            voiceBag = speeches.shuffled()
        }
        guard !speeches.isEmpty else {
            say("No voices found in Music/Blend/Speeches")
            return
        }
        let pool = wanted.map { [$0] } ?? voiceBag
        let s = engine.state, now = s.masterBeat, bps = max(0.5, s.masterBpm / 60)
        var pick = pool[0], start = Double.nan, landing = ""
        if let c = current, !paused {
            let marks = voiceMarks(s)
            var best = Double.infinity
            for clip in pool {
                guard let fit = voiceFit(clip, marks, now: now, bps: bps), fit.cost < best else { continue }
                best = fit.cost
                pick = clip
                start = fit.start
                landing = String(format: ", lands on beat %.1f", fit.mark)
            }
            if start.isNaN {
                let d = s.deck(c)
                start = (d.beat + 0.5).rounded(.up) - d.offset
            }
        }
        voiceBag.removeAll { $0.id == pick.id }
        let from = start.isNaN ? now : start, bars = Int(((from - now) / 4).rounded())
        log?(String(format: "voice %@ (%.1f s) starts at beat %.2f%@", pick.id as NSString, pick.seconds, from, landing as NSString))
        fire(pick, range: nil, start: start, note: pick.speaker + " · " + pick.title + (bars >= 2 ? " · in \(bars) bars" : ""))
    }

    public func speakWords(_ speech: Speech, from: Double, to: Double, label: String) {
        if speaking != nil {
            engine.cancel(tag: voiceTag)
            engine.event(Int32(BE_EV_VOICE_STOP), deck: -1, at: .nan)
            speaking = nil
        }
        guard to > from else { return }
        let s = engine.state
        var start = Double.nan
        if let c = current, !paused {
            let d = s.deck(c)
            start = (d.beat + 0.3).rounded(.up) - d.offset - Speeches.lead * max(0.5, s.masterBpm / 60)
        }
        log?(String(format: "word %@ \"%@\" %.2f-%.2f s starts at beat %.2f", speech.id as NSString, label as NSString, from, to, start.isNaN ? s.masterBeat : start))
        fire(speech, range: from...to, start: start, note: speech.speaker + " · “" + label + "”")
    }

    private func fire(_ pick: Speech, range: ClosedRange<Double>?, start: Double, note: String) {
        speaking = pick
        voiceHeard = false
        voiceFrom = start.isNaN ? engine.state.masterBeat : start
        voiceTag = nextTag()
        let tag = voiceTag, gain = voiceGain
        say(note)
        let engine = self.engine
        voiceLoader(pick, range) { [weak self] clip in
            guard let self, self.speaking?.id == pick.id, self.voiceTag == tag, let clip else {
                if let clip { be_track_release(clip) }
                if let self, self.speaking?.id == pick.id, self.voiceTag == tag { self.speaking = nil }
                return
            }
            engine.loadVoice(clip)
            be_track_release(clip)
            engine.event(Int32(BE_EV_VOICE), deck: -1, at: start, value: gain, tag: tag)
        }
    }

    public func setEffect(_ new: Effect?) {
        effect = new
        engine.setOutputEffect(new?.rawValue ?? 0)
        log?("effect \(new?.label ?? "off")")
    }

    public func toggleEffect(_ e: Effect) { setEffect(effect == e ? nil : e) }

    public func cycleEffect() {
        let all: [Effect?] = [nil] + Effect.allCases.map { $0 }
        let i = all.firstIndex { $0 == effect } ?? 0
        setEffect(all[(i + 1) % all.count])
        say(effect.map { "\($0.label): \($0.help)" } ?? "Effect off")
    }

    public func setStyle(_ new: Technique?) {
        style = new
        plan = nil
        planEpoch += 1
    }

    private func pick(_ options: [Technique]) -> Technique {
        var best = options[0]
        for o in options.dropFirst() where (used[o] ?? -1) < (used[best] ?? -1) { best = o }
        return best
    }

    private func note(_ tech: Technique) {
        used[tech] = useCount
        useCount += 1
        if tech == .bridge {
            bridgeRun += 1
        } else if !tech.blends {
            bridgeRun = 0
        }
    }

    private func effectiveKey(_ deck: Int) -> Int {
        guard let t = decks[deck].track else { return 0 }
        let k = t.analysis.key
        return ((k % 12 + decks[deck].pitch) % 12 + 12) % 12 + (k >= 12 ? 12 : 0)
    }

    private func say(_ text: String) {
        if hint == text, Date() < hintUntil.addingTimeInterval(-1.6) { return }
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

    public func scratchMove(_ deck: Int, frames: Double, seconds: Double) {
        if scratching[deck] { engine.scratchMove(deck, frames: frames, seconds: seconds) }
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
        case .spin: cut(.spin)
        case .drop: dropJump()
        case .loop: toggleLoop()
        case .roll: rollBegin(hold: false)
        case .quick: quickSwitch()
        case .voice: speak()
        case .word: break
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
        switch tr.technique {
        case _ where tr.style == .blend: commit(&tr)
        case .roll: cut(.build, technique: .roll)
        case .spin: cut(.spin, technique: .spin)
        default: cut(.echo, lead: 4, technique: .wash)
        }
    }

    private func nextBar(_ st: Structure, after beat: Double, ahead: Double, every: Int) -> Int {
        var b = st.bar(atBeat: beat + ahead) + 1
        while !st.isPhrase(b, every: every) { b += 1 }
        return b
    }

    private func twinAnchors(_ a: LoadedTrack, _ b: LoadedTrack) -> [(from: Int, to: Int)]? {
        if let t = a.info.twin, t.of == b.info.id { return t.map.filter { $0.count == 2 }.map { (from: $0[0], to: $0[1]) } }
        if let t = b.info.twin, t.of == a.info.id {
            if let back = t.back { return back.filter { $0.count == 2 }.map { (from: $0[0], to: $0[1]) } }
            return t.map.filter { $0.count == 2 }.map { (from: $0[1], to: $0[0]) }
        }
        return nil
    }

    private func twinShift(_ a: LoadedTrack, _ b: LoadedTrack) -> Int? {
        if let t = a.info.twin, t.of == b.info.id { return t.semitones }
        if let t = b.info.twin, t.of == a.info.id { return -t.semitones }
        return nil
    }

    private func twinRuns(_ a: LoadedTrack, bar: Int, bars: Int, _ b: LoadedTrack) -> Bool {
        guard let first = twinBar(a, bar: bar, b), let last = twinBar(a, bar: bar + bars - 1, b) else { return false }
        return last - first == bars - 1 && last < b.structure.lastStrong
    }

    private func twinBar(_ a: LoadedTrack, bar: Int, _ b: LoadedTrack) -> Int? {
        guard let anchors = twinAnchors(a, b), let first = anchors.min(by: { ($0.from, $0.to) < ($1.from, $1.to) }) else { return nil }
        guard let hit = anchors.filter({ $0.from <= bar }).max(by: { ($0.from, -$0.to) < ($1.from, -$1.to) }) else { return max(0, first.to - (first.from - bar)) }
        let room = max(8, (b.structure.lastStrong - 8 - hit.to) / 8 * 8)
        return bar - hit.from < room ? hit.to + (bar - hit.from) : nil
    }

    private func twinStart(_ a: LoadedTrack, _ b: LoadedTrack, after now: Int, bars: Int) -> Int? {
        guard twinAnchors(a, b) != nil else { return nil }
        let sa = a.structure, limit = b.structure.bars * 2 / 5
        var best: Int?
        for bar in (sa.bars * 3 / 10)..<max(sa.bars * 3 / 10, sa.lastStrong - bars + 1) where bar > now && sa.isPhrase(bar, every: 4) {
            if let m = twinBar(a, bar: bar, b), m <= limit, twinRuns(a, bar: bar, bars: bars, b) { best = bar }
        }
        return best
    }

    private func entry(_ b: LoadedTrack, lead: Int, voice: Int) -> (bar: Int, delay: Int) {
        let sb = b.structure, intro = sb.firstFull - sb.startBar
        var bar = intro > lead && intro <= 32 ? sb.firstFull - lead : sb.startBar
        if sb.stemPresent[Stem.vocals.rawValue], let sung = sb.vocalStarts.first { bar = min(bar, sb.phraseStart(atOrBefore: sung, every: 4) - voice) }
        return (max(sb.startBar, bar), min(lead, max(0, sb.startBar - bar)))
    }

    private func vocalGap(_ a: LoadedTrack, at bar: Int) -> Bool {
        let voice = a.structure.level[Stem.vocals.rawValue]
        guard bar >= 0, bar + 1 < voice.count else { return true }
        return voice[bar] <= 0.25 && voice[bar + 1] <= 0.3
    }

    private func carries(_ a: LoadedTrack, _ b: LoadedTrack, from bar: Int, bars n: Int, entry: Int) -> Bool {
        let sa = a.structure, sb = b.structure
        guard n >= 8, sa.stemPresent[Stem.vocals.rawValue], sb.stemPresent[Stem.drums.rawValue] else { return false }
        func mean(_ v: [Float], _ r: Range<Int>) -> Float {
            let c = r.clamped(to: 0..<v.count)
            return c.isEmpty ? 0 : v[c].reduce(0, +) / Float(c.count)
        }
        let sung = mean(sa.level[0], (bar + n / 2)..<(bar + n * 7 / 8))
        let quiet = mean(sb.level[0], max(0, entry)..<(max(0, entry) + n * 7 / 8))
        return sung > 0.45 && quiet < 0.2
    }

    private func planBlend(from f: Int, to t: Int, auto: Bool, byHand: Bool = false, _ s: be_state) -> Transition? {
        guard let a = decks[f].track, let b = decks[t].track else { return nil }
        let sa = a.structure, sb = b.structure
        let da = s.deck(f), db = s.deck(t)
        let toPlaying = db.playing != 0
        let related = toPlaying ? nil : twinShift(a, b)
        let home = a.analysis.bpm
        let ratio = b.analysis.bpm / home
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
        let far = !toPlaying && !byHand && (ratio > 1.22 || ratio < 0.82)
        let wide = !toPlaying && !far && (ratio > 1.11 || ratio < 0.9)
        let keyed = Key.match(effectiveKey(f), toPlaying ? effectiveKey(t) : b.analysis.key)
        let sure = toPlaying || min(a.analysis.keyStrength, b.analysis.keyStrength) >= 0.05
        let clash = related == nil && (!sure || keyed.score < 2 || abs(keyed.shift) > 1 || (toPlaying && keyed.shift != 0))
        let stems = a.stems == 4 && b.stems == 4
        let drums = sb.stemPresent[Stem.drums.rawValue]
        let loopable = stems && drums && sa.stemPresent[Stem.drums.rawValue] && !toPlaying && !byHand && ratio > 0.6 && ratio < 1.67
        let endBar = sa.finish
        let here = sa.bar(atBeat: da.beat)

        func place(_ want: Int) -> (bar: Int, bars: Int) {
            var bars = want, bar: Int
            if auto, !far, related != nil, let early = twinStart(a, b, after: here, bars: want) {
                bar = early
            } else if auto {
                bar = sa.phraseStart(atOrBefore: endBar - bars, every: 4)
                if sa.beat(ofBar: bar) < da.beat + 1 { bar = nextBar(sa, after: da.beat, ahead: 1, every: 4) }
            } else {
                bar = nextBar(sa, after: da.beat, ahead: 1, every: mash != nil ? 2 : 4)
            }
            let left = max(2, endBar - bar)
            while bars > 2 && bars > left { bars /= 2 }
            if related != nil, twinBar(a, bar: bar, b) != nil {
                while bars > 2 && !twinRuns(a, bar: bar, bars: bars, b) { bars /= 2 }
            }
            return (bar, bars)
        }

        var (bar, bars) = place(n)
        var options: [Technique]
        if far {
            options = loopable && bars >= 8 && bridgeRun < 2 ? [.bridge] : [.wash, .roll, .spin]
        } else if toPlaying || byHand || !stems {
            options = clash ? [.ride] : stems && !toPlaying ? [.swap, .melt] : [.swap]
        } else if clash {
            options = bars >= 4 && drums ? [.ride, .loop, .chop] : [.ride]
        } else {
            options = carries(a, b, from: bar, bars: bars, entry: twinBar(a, bar: bar, b) ?? entry(b, lead: bars / 2, voice: bars * 7 / 8).bar) ? [.carry, .swap, .melt] : [.swap, .melt]
        }
        var tech = pick(options)
        if let forced = style, forced != tech {
            var able = !far && !toPlaying && !byHand && (stems || !forced.needsStems) && (bars >= 4 || !forced.scripted)
            if forced == .carry, bars < 8 || !sa.stemPresent[Stem.vocals.rawValue] { able = false }
            if forced == .bridge { able = loopable && bars >= 8 }
            if options.contains(forced) || (!forced.blends && !byHand && !toPlaying) || (forced.blends && able) {
                tech = forced
            } else if !auto, !byHand {
                say("\(forced.label) does not fit this pair, using \(tech.label)")
            }
        }
        if tech == .chop, bars > 8 { (bar, bars) = place(8) }
        let twin = toPlaying ? nil : twinBar(a, bar: bar, b)
        let lead = tech == .loop || tech == .chop ? bars : tech == .ride || tech == .bridge ? bars * 3 / 4 : bars / 2
        if auto, twin == nil, tech.blends, tech != .carry, sa.stemPresent[Stem.vocals.rawValue] {
            var cut = lead
            if tech == .bridge { cut = 0 }
            if tech == .loop { cut = bars / 2 }
            if tech == .chop { cut = bars - 2 }
            for shift in [0, 4, -4, 8] {
                let trial = bar + shift
                if sa.beat(ofBar: trial) >= da.beat + 1, trial + bars < sa.bars, vocalGap(a, at: trial + cut) {
                    bar = trial
                    break
                }
            }
        }
        var cue = entry(b, lead: lead, voice: tech == .carry ? bars * 7 / 8 : lead)
        if tech == .bridge {
            cue = entry(b, lead: bars / 4, voice: bars / 4)
            cue.delay += bars / 2
        }
        let toBeat = sb.beat(ofBar: twin ?? (toPlaying ? 0 : cue.bar))
        let length = Double(bars * 4)
        var nudge = 0.0
        let ka = toPlaying || !tech.blends ? 0 : a.kickOffset(fromBeat: sa.beat(ofBar: bar), beats: max(16, bars * 4))
        let kb = toPlaying || !tech.blends ? 0 : b.kickOffset(fromBeat: max(toBeat, sb.beat(ofBar: twin == nil ? sb.firstFull : 0)), beats: 32)
        nudge = max(-0.05, min(0.05, ka * a.analysis.bpm / 60 - kb * b.analysis.bpm / 60))
        var tr = Transition(style: .blend, from: f, to: t, startBeat: sa.beat(ofBar: bar) - da.offset, length: length, toTrackBeat: toBeat - nudge,
                            tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: nextTag())
        tr.technique = tech
        tr.toWasPlaying = toPlaying
        tr.twin = twin != nil
        tr.toDelay = twin == nil && !toPlaying && !byHand && tech.blends ? Double(cue.delay * 4) : 0
        if !tech.blends {
            tr.style = tech == .wash ? .echo : tech == .roll ? .build : .spin
            return tr
        }
        tr.clash = clash
        tr.pitch = clash || toPlaying || tech == .bridge ? 0 : related.map { decks[f].pitch + $0 } ?? keyed.shift
        tr.wide = wide && !byHand && tech != .bridge
        tr.lanes = Lanes.blend(tech, from: f, to: t, fromStems: a.stems == 4, toStems: b.stems == 4, toDrums: drums, toPlaying: toPlaying, beats: length) { deck, param in
            Double(s.deck(deck).param(param))
        }
        let meet = (home * b.analysis.bpm).squareRoot()
        var glide: (p0: Double, p1: Double, v: Double) = (p0: 0.0, p1: 1.0, v: b.analysis.bpm)
        if tech == .bridge {
            glide = (p0: 0.25, p1: 0.625, v: b.analysis.bpm)
        } else if tr.wide {
            glide = (p0: 0.0, p1: 0.3, v: meet)
        }
        tr.lanes.append(Lane(deck: -1, param: Int32(BE_P_TEMPO), base: s.masterBpm, applyBase: false, segs: [glide]))
        if tech == .loop { tr.cues = Lanes.loopCues(deck: f, beats: length, trackBeat: sa.beat(ofBar: bar) + length / 2) }
        if tech == .bridge { tr.cues = Lanes.bridgeCues(deck: f, beats: length, trackBeat: sa.beat(ofBar: bar) + length / 4) }
        log?("plan \(tech.rawValue) \(a.info.title) bar \(bar) -> \(b.info.title) bar \(sb.bar(atBeat: toBeat)) (starts at \(sb.startBar), full at \(sb.firstFull), delay \(Int(tr.toDelay / 4)) bars), kicks \(String(format: "%+.1f / %+.1f", ka * 1000, kb * 1000)) ms, nudge \(String(format: "%+.1f", nudge * 60000 / b.analysis.bpm)) ms, \(bars) bars, clash \(clash), wide \(tr.wide), twin \(tr.twin), key shift \(tr.pitch), tempo \(tr.tempoFrom) -> \(tr.tempoTo)")
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
            engine.start(tr.to, at: tr.startBeat + tr.toDelay, trackBeat: tr.toTrackBeat, tag: tr.tag)
        }
        schedule(tr, from: 0, start: tr.startBeat, length: tr.length)
        note(tr.technique)
        tr.committed = true
        tr.manual = false
        transition = tr
        plan = nil
        log?("commit \(tr.technique.rawValue) start \(tr.startBeat) length \(tr.length)")
    }

    private func schedule(_ tr: Transition, from p0: Double, start: Double, length: Double) {
        let span = max(1e-6, 1 - p0)
        func at(_ p: Double) -> Double { start + (p - p0) / span * length }
        for lane in tr.lanes {
            for seg in lane.segs where seg.p1 > p0 { engine.ramp(deck: lane.deck, lane.param, to: seg.v, start: at(max(seg.p0, p0)), end: at(seg.p1), tag: tr.tag) }
        }
        for cue in tr.cues where cue.p >= p0 { engine.event(cue.type, deck: cue.deck, at: at(cue.p), value: cue.value, from: cue.from, tag: tr.tag) }
        engine.stop(tr.from, at: start + length, tag: tr.tag)
    }

    private func applyManual(_ tr: Transition) {
        for lane in tr.lanes { engine.set(lane.deck, lane.param, Float(lane.value(at: tr.progress))) }
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
            guard mash == nil else {
                say("Turn the mashup off first")
                return
            }
            guard let n = nextDeck, let a = decks[c].track, let b = decks[n].track else {
                say(queue.isEmpty ? "Queue a song to blend into" : "Next song is still loading")
                return
            }
            let ratio = b.analysis.bpm / a.analysis.bpm
            guard ratio < 1.34, ratio > 0.75 else {
                say("Too far apart in tempo to blend by hand, press space")
                return
            }
            guard var tr = planBlend(from: c, to: n, auto: false, byHand: true, s), tr.style == .blend else { return }
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
            if tr.technique.scripted {
                say("\(tr.technique.label) runs on its own")
                return
            }
            if s.deck(tr.to).playing == 0 { return }
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
        if tr.style == .blend, abs(engine.state.masterBpm - tr.tempoTo) > 0.05 { engine.tempoRamp(to: tr.tempoTo, start: beat, end: beat + 32, tag: nextTag()) }
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
        if let same = twinBar(a, bar: bar, b) { bBar = same }
        let tag = nextTag()
        let match = Key.match(effectiveKey(c), b.analysis.key)
        let shift = twinShift(a, b).map { decks[c].pitch + $0 } ?? (match.score > 0 ? match.shift : 0)
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

    private func entryBeat(_ t: LoadedTrack, slam: Bool = false) -> Double {
        let st = t.structure, first = max(0, st.firstSound)
        return st.beat(ofBar: slam && st.firstFull > first && st.firstFull - first <= 4 ? st.firstFull : first)
    }

    private func prepareFull(_ deck: Int) {
        for st in Stem.allCases { engine.set(deck, st.param, 1) }
        for st in 0..<4 { engine.set(deck, Int32(BE_P_USER0) + Int32(st), decks[deck].stemOn[st] ? 1 : 0) }
        engine.set(deck, Int32(BE_P_VOLUME), 1)
        engine.set(deck, Int32(BE_P_FILTER), 0)
        engine.set(deck, Int32(BE_P_ECHO), 0)
    }

    private func cut(_ style: Transition.Style, lead: Double = 0, technique: Technique? = nil) {
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
        func line(_ ahead: Double) -> Double { sa.beat(ofBar: nextBar(sa, after: da.beat, ahead: ahead, every: 1)) - da.offset }
        var tr: Transition?
        switch style {
        case .build:
            let short = technique == .roll && n != nil && b != nil
            let span = short ? 8.0 : 16.0
            let end = short ? line(9.5) : line(0.5) + 16, start = end - span
            engine.ramp(deck: c, filter, to: short ? 0.6 : 0.72, start: start, end: end, curve: .easeIn, tag: tag)
            for (before, len) in [(8.0, 1.0), (4.0, 0.5), (2.0, 0.25), (1.0, 0.125)] {
                engine.event(Int32(BE_EV_ROLL), deck: c, at: end - (short ? before / 2 : before), value: len, tag: tag)
            }
            engine.event(Int32(BE_EV_UNROLL), deck: c, at: end, tag: tag)
            if let n, let b {
                let landing = short ? entryBeat(b, slam: true) : dropBeat(b)
                prepareFull(n)
                engine.start(n, at: end, trackBeat: landing, tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                engine.stop(c, at: end, tag: tag)
                tr = Transition(style: .build, from: c, to: n, startBeat: start, length: span, toTrackBeat: landing, tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
                tr?.name = short ? "ROLL" : "BUILD"
            } else {
                engine.ramp(deck: c, filter, to: 0, start: end, end: end + 0.03, tag: tag)
                busyUntil = end + 1
            }
        case .echo:
            let washed = lead > 0 && n != nil && b != nil
            let end = line(1.5 + (washed ? lead : 0))
            if washed {
                engine.ramp(deck: c, filter, to: 0.62, start: end - lead, end: end - 0.5, curve: .easeIn, tag: tag)
                engine.ramp(deck: c, echo, to: 0.65, start: end - min(lead, 3), end: end - 0.5, tag: tag)
            } else {
                engine.ramp(deck: c, echo, to: 1, start: end - 1, end: end - 0.5, tag: tag)
            }
            if let n, let b {
                prepareFull(n)
                engine.ramp(deck: c, volume, to: 0, start: end - 0.08, end: end, tag: tag)
                engine.ramp(deck: c, echo, to: 0, start: end, end: end + 0.05, tag: tag)
                engine.start(n, at: end, trackBeat: entryBeat(b), tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                engine.stop(c, at: end + 0.1, tag: tag)
                let span = washed ? lead : 1
                tr = Transition(style: .echo, from: c, to: n, startBeat: end - span, length: span, toTrackBeat: entryBeat(b), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
                tr?.name = washed ? "WASH" : "ECHO"
            } else {
                engine.ramp(deck: c, echo, to: 0, start: end, end: end + 0.1, tag: tag)
            }
        case .spin:
            guard let n, let b else {
                say(queue.isEmpty ? "Queue a song to spin into" : "Next song is still loading")
                return
            }
            let end = line(2.5)
            engine.event(Int32(BE_EV_SPIN), deck: c, at: end - 1.5, value: 1.5, tag: tag)
            engine.ramp(deck: c, volume, to: 0, start: end - 0.7, end: end - 0.04, tag: tag)
            prepareFull(n)
            engine.start(n, at: end, trackBeat: entryBeat(b, slam: true), tag: tag)
            engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
            engine.stop(c, at: end, tag: tag)
            tr = Transition(style: .spin, from: c, to: n, startBeat: end - 2, length: 2, toTrackBeat: entryBeat(b, slam: true), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
            tr?.name = "SPIN"
        case .brake:
            let end = line(2)
            engine.event(Int32(BE_EV_BRAKE), deck: c, at: end - 1, value: 1, tag: tag)
            if let n, let b {
                prepareFull(n)
                engine.start(n, at: end, trackBeat: entryBeat(b), tag: tag)
                engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
                tr = Transition(style: .brake, from: c, to: n, startBeat: end - 1, length: 1, toTrackBeat: entryBeat(b), tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
                tr?.name = "BRAKE"
            } else {
                pauseAfterBrake = true
            }
        case .blend:
            break
        }
        if var tr {
            if let technique {
                tr.technique = technique
                note(technique)
            }
            tr.committed = true
            transition = tr
            plan = nil
            log?("commit \(tr.label.lowercased()) start \(tr.startBeat) end \(tr.endBeat)")
        }
    }

    private func quickSwitch() {
        guard let c = current, !paused, let a = decks[c].track else { return }
        guard transition == nil else {
            say("Wait for the mix to finish")
            return
        }
        guard mash == nil else {
            say("Turn the mashup off first")
            return
        }
        guard let n = nextDeck, let b = decks[n].track else {
            say(queue.isEmpty ? "Queue a song to switch to" : "Next song is still loading")
            return
        }
        let s = engine.state, sa = a.structure, sb = b.structure, da = s.deck(c)
        let first = sa.bar(atBeat: da.beat + 6) + 1
        var bar = first, best = -100.0
        for trial in first..<(first + 5) {
            var score = -0.3 * Double(trial - first)
            if sa.isPhrase(trial, every: 4) {
                score += 2
            } else if sa.isPhrase(trial, every: 2) {
                score += 1
            }
            if !sa.stemPresent[Stem.vocals.rawValue] || vocalGap(a, at: trial) { score += 1.5 }
            if score > best {
                best = score
                bar = trial
            }
        }
        var land = sb.firstFull - sb.startBar <= 32 ? sb.firstFull : max(0, sb.firstSound)
        if land >= 0, land + 4 <= sb.bars {
            let base = sb.total[land..<(land + 4)].reduce(0, +) / 4
            for bar in land..<min(sb.bars - 4, land + 17) where sb.total[bar..<(bar + 4)].reduce(0, +) / 4 >= max(0.7, base * 1.4) {
                land = bar
                break
            }
        }
        if sb.stemPresent[Stem.vocals.rawValue], let sung = sb.vocalStarts.first, sung < land { land = max(0, sb.phraseStart(atOrBefore: sung, every: 4)) }
        let landing = sb.beat(ofBar: land)
        let end = sa.beat(ofBar: bar) - da.offset, tag = nextTag()
        let filter = Int32(BE_P_FILTER), echo = Int32(BE_P_ECHO), volume = Int32(BE_P_VOLUME)
        let ratio = b.analysis.bpm / a.analysis.bpm
        engine.ramp(deck: c, filter, to: 0.5, start: end - 4, end: end - 0.25, curve: .easeIn, tag: tag)
        engine.ramp(deck: c, echo, to: 0.6, start: end - 2, end: end - 1, tag: tag)
        engine.event(Int32(BE_EV_ROLL), deck: c, at: end - 1, value: 0.5, tag: tag)
        engine.event(Int32(BE_EV_ROLL), deck: c, at: end - 0.5, value: 0.25, tag: tag)
        engine.event(Int32(BE_EV_UNROLL), deck: c, at: end, tag: tag)
        engine.ramp(deck: c, volume, to: 0, start: end - 0.06, end: end, tag: tag)
        engine.ramp(deck: c, echo, to: 0, start: end, end: end + 0.05, tag: tag)
        prepareFull(n)
        engine.start(n, at: end, trackBeat: landing, tag: tag)
        if ratio <= 1.11, ratio >= 0.9 {
            engine.tempoRamp(to: b.analysis.bpm, start: end, end: end + 8, tag: tag)
        } else {
            engine.tempoRamp(to: b.analysis.bpm, start: end, end: end, tag: tag)
        }
        engine.stop(c, at: end + 0.1, tag: tag)
        var tr = Transition(style: .echo, from: c, to: n, startBeat: end - 4, length: 4, toTrackBeat: landing, tempoFrom: s.masterBpm, tempoTo: b.analysis.bpm, tag: tag)
        tr.name = "SWITCH"
        tr.committed = true
        transition = tr
        plan = nil
        log?("commit switch at \(a.info.title) bar \(bar) -> \(b.info.title) bar \(land), end \(end)")
    }

    public func rollBegin(hold: Bool = true) {
        guard let c = current, !paused, decks[c].track != nil, transition?.style != .build else { return }
        let d = engine.state.deck(c)
        guard d.rolling == 0, d.playing != 0 else { return }
        let at = ((d.beat + 0.06) * 2).rounded(.up) / 2 - d.offset
        rollTag = nextTag()
        rollLen = 0.5
        rollDeck = c
        engine.event(Int32(BE_EV_ROLL), deck: c, at: at, value: rollLen, tag: rollTag)
        if !hold { engine.event(Int32(BE_EV_UNROLL), deck: c, at: at + 2, tag: rollTag) }
    }

    public func rollEnd() {
        guard let d = rollDeck else { return }
        rollDeck = nil
        engine.cancel(tag: rollTag)
        engine.event(Int32(BE_EV_UNROLL), deck: d, at: .nan)
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
        if let d = rollDeck, da.rolling != 0 {
            if factor < 1 {
                rollLen = max(0.0625, rollLen * factor)
                engine.event(Int32(BE_EV_ROLL), deck: d, at: .nan, value: rollLen)
            }
            return
        }
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
        let rollNow = current.map { s.deck($0).rolling != 0 } ?? false
        if rollNow != rolling { rolling = rollNow }
        var pulse = -1
        if let c = current, let t = decks[c].track, s.deck(c).playing != 0 {
            pulse = ((Int(floor(s.deck(c).beat)) - t.structure.barPhase) % 4 + 4) % 4
        }
        if pulse != beatInBar { beatInBar = pulse }
        if speaking != nil {
            if s.voicePlaying != 0 {
                voiceHeard = true
            } else if voiceHeard || beat > voiceFrom + 12 {
                speaking = nil
            }
        }
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
            if upcoming != nil { upcoming = nil }
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
            if upcoming != nil { upcoming = nil }
            return
        }
        let key = "\(a.info.id)|\(b.info.id)|\(s.epoch)|\(planEpoch)"
        if plan == nil || planKey != key {
            plan = planBlend(from: c, to: n, auto: true, s)
            planKey = key
        }
        if upcoming != plan?.technique { upcoming = plan?.technique }
        guard var p = plan else { return }
        let left = p.startBeat - beat
        let shown = max(0, Int((left / 4).rounded(.up)))
        if countdownBars != shown { countdownBars = shown }
        if p.style == .blend {
            if left < 6 {
                if left > 0.5 {
                    commit(&p)
                } else {
                    plan = nil
                }
            }
            return
        }
        switch p.technique {
        case .roll where left < 13.4 && left > 9.6: cut(.build, technique: .roll)
        case .spin where left < 6.4 && left > 3.4: cut(.spin, technique: .spin)
        case .wash where left < 21.4 && left > 17.6: cut(.echo, lead: 16, technique: .wash)
        case .wash where left < 13.4 && left > 9.6: cut(.echo, lead: 8, technique: .wash)
        default:
            if left < 5.4, left > 2.2 {
                cut(.echo, technique: .wash)
            } else if left <= 0.5 {
                plan = nil
            }
        }
    }
}
