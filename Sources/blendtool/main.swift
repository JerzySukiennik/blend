// blendtool: offline tests for the Blend engine, the trackpad gesture rules and the library (no audio output).
import BlendEngine
import BlendKit
import Foundation

func clickTrack(bpm: Double, seconds: Double, stems: Int = 4) -> OpaquePointer {
    let sr = 44100.0
    let frames = Int(seconds * sr)
    let t = be_track_create(Int32(stems), Int64(frames))!
    let fpb = sr * 60 / bpm
    let first = 0.25 * sr
    for s in 0..<stems {
        let p = be_track_stem(t, Int32(s))!
        if s == 1 || stems == 1 {
            var b = 0
            while first + Double(b) * fpb + 400 < Double(frames) {
                let at = Int((first + Double(b) * fpb).rounded())
                for i in 0..<300 {
                    let v = sin(Double(i) * 2 * .pi * 1800 / sr) * exp(-Double(i) / 40) * 20000
                    p[(at + i) * 2] = Int16(v)
                    p[(at + i) * 2 + 1] = Int16(v)
                }
                b += 1
            }
        } else {
            let f = [220.0, 0, 55.0, 330.0][s]
            for i in 0..<frames {
                let v = Int16(sin(Double(i) * 2 * .pi * f / sr) * 2500)
                p[i * 2] = v
                p[i * 2 + 1] = v
            }
        }
    }
    be_track_set_grid(t, bpm, first)
    return t
}

func renderMono(_ e: Engine, seconds: Double, block: Int = 512, tick: ((Double) -> Void)? = nil) -> [Float] {
    let total = Int(seconds * e.sampleRate)
    var out = [Float](repeating: 0, count: total)
    var l = [Float](repeating: 0, count: block), r = [Float](repeating: 0, count: block)
    var done = 0
    while done < total {
        let n = min(block, total - done)
        tick?(Double(done) / e.sampleRate)
        e.render(&l, &r, n)
        for i in 0..<n { out[done + i] = l[i] }
        done += n
    }
    return out
}

func clicks(_ x: [Float], threshold: Float = 0.1) -> [Int] {
    var res: [Int] = []
    var i = 0
    while i < x.count {
        if abs(x[i]) > threshold {
            var pk = i
            for j in i..<min(x.count, i + 600) where abs(x[j]) > abs(x[pk]) { pk = j }
            res.append(pk)
            i += 4000
        } else {
            i += 1
        }
    }
    return res
}

func selftest() {
    let a = clickTrack(bpm: 120, seconds: 60), b = clickTrack(bpm: 126, seconds: 60)
    func run(audible: Int) -> [Int] {
        let e = Engine()
        e.load(0, a)
        e.load(1, b)
        for d in 0..<2 {
            for s in Stem.allCases { e.set(d, s.param, (d == audible && s == .drums) ? 1 : 0) }
        }
        e.play(0, trackBeat: 0)
        e.start(1, at: 16, trackBeat: 8)
        e.tempoRamp(to: 126, start: 16, end: 48)
        let x = renderMono(e, seconds: 34)
        return clicks(x)
    }
    let ca = run(audible: 0), cb = run(audible: 1)
    var worst = 0, count = 0
    for t in cb {
        guard let near = ca.min(by: { abs($0 - t) < abs($1 - t) }) else { continue }
        worst = max(worst, abs(near - t))
        count += 1
    }
    print("sync: A clicks \(ca.count), B clicks \(cb.count), compared \(count), worst offset \(worst) samples (\(String(format: "%.2f", Double(worst) / 44.1)) ms)")
    let firstB = cb.first ?? 0
    print("B first click at \(String(format: "%.4f", Double(firstB) / 44100)) s, expected near \(String(format: "%.4f", 0.25 + 16 * 0.5)) s")
    let gaps = zip(ca.dropFirst(), ca).map { $0 - $1 }
    print("A beat gap start \(gaps.first ?? 0) end \(gaps.last ?? 0) samples (120 BPM = 22050, 126 BPM = 21000)")

    let e = Engine()
    e.load(0, a)
    e.load(1, b)
    e.play(0, trackBeat: 0)
    e.start(1, at: 4, trackBeat: 0)
    e.tempoRamp(to: 123, start: 4, end: 8)
    var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
    for _ in 0..<400 { e.render(&l, &r, 512) }
    let t0 = Date()
    let blocks = 2584
    for _ in 0..<blocks { e.render(&l, &r, 512) }
    let dt = Date().timeIntervalSince(t0)
    let audio = Double(blocks * 512) / 44100
    print("cpu: 8 stems stretching, \(String(format: "%.1f", audio)) s of audio in \(String(format: "%.2f", dt)) s = \(String(format: "%.1f", dt / audio * 100))% of one core, engine load \(String(format: "%.3f", e.state.load))")
    print("state: beat \(String(format: "%.2f", e.state.masterBeat)) bpm \(e.state.masterBpm) stretching \(e.state.deck.0.stretching)/\(e.state.deck.1.stretching)")

    let d = Engine()
    d.load(0, a)
    d.play(0, trackBeat: 0)
    let y = renderMono(d, seconds: 3)
    let src = be_track_stem(a, 1)!
    var maxErr: Float = 0
    for i in 20000..<100000 {
        var s: Float = 0
        for st in 0..<4 { s += Float(be_track_stem(a, Int32(st))![(i + 11025) * 2]) / 32768 }
        maxErr = max(maxErr, abs(y[i] - s * 0.84))
    }
    _ = src
    print("direct path max error vs source: \(maxErr)")
    be_track_release(a)
    be_track_release(b)
}

func describe(_ t: LoadedTrack) -> String {
    let a = t.analysis, s = t.structure
    func bars(_ v: [Int]) -> String { v.map(String.init).joined(separator: ",") }
    let line = (0..<s.bars).map { b -> String in
        let i = s.intensity[b]
        return i >= 0.62 ? "#" : i >= 0.3 ? "+" : s.total[b] > 0.12 ? "-" : "."
    }.joined()
    let vox = (0..<s.bars).map { s.level[0][$0] > 0.4 ? "v" : " " }.joined()
    let w = t.warp
    let numbers = String(format: "tracker %.2f -> %.2f, kicks %.2f -> %.2f, drift %.0f ms, speed %.3f..%.3f%@%@", w.before, w.after, w.tightBefore, w.tightAfter, w.drift * 1000, w.rateLow, w.rateHigh,
                         w.half == 1 ? ", half beats" : "", w.bent == 1 ? ", pitch corrected" : "")
    let warp = (w.lead < 0 ? "\n   no drum stem, rhythm read from the full mix" : "") + (w.applied == 1 ? "\n   straightened: " + numbers : w.anchors > 0 ? "\n   left as is: " + numbers : "")
    return String(format: "%-34@ %7.3f BPM  key %-3@ (%.2f)  conf %.2f  gain %.2f  first %.0f  bar+%d phrase+%d  bars %d  drops [%@]  vocals [%@]  full@%d last@%d",
                  t.info.title as NSString, a.bpm, a.keyName as NSString, a.keyStrength, a.confidence, a.gain, a.firstBeatFrame, s.barPhase, s.phrasePhase, s.bars,
                  bars(s.drops) as NSString, bars(s.vocalStarts) as NSString, s.firstFull, s.lastStrong) + "\n   " + line + "\n   " + vox + warp
}

func tightness(_ t: LoadedTrack) -> String {
    let hop = 64, frames = Int(be_track_frames(t.raw))
    let wanted: [Int32] = t.stems == 4 ? (t.structure.stemPresent[1] ? [1] : [0, 1, 2, 3]) : [0]
    let sources = wanted.compactMap { be_track_stem(t.raw, $0) }
    guard !sources.isEmpty, frames > hop * 16 else { return "" }
    var env = [Float](repeating: 0, count: frames / hop)
    let k = 1 - exp(-2 * Float.pi * 130 / 44100)
    let broad = sources.count > 1, lag = broad ? 16 : 6
    var a: Float = 0, b: Float = 0, last: Float = 0
    for m in 0..<env.count {
        var acc: Float = 0
        for i in 0..<hop {
            let j = (m * hop + i) * 2
            var v: Float = 0
            for p in sources { v += Float(p[j]) + Float(p[j + 1]) }
            if broad {
                acc += abs(v - last)
                last = v
            } else {
                a += k * (v - a)
                b += k * (a - b)
                acc += abs(b)
            }
        }
        env[m] = broad ? acc.squareRoot() : acc / Float(hop * 65536)
    }
    var hits: [(beat: Int, off: Double, peak: Float)] = []
    let reach = Int(0.22 * t.fpb / Double(hop))
    for b in 0..<t.analysis.beats {
        let c = Int(((t.analysis.firstBeatFrame + Double(b) * t.fpb) / Double(hop)).rounded())
        guard c - reach >= lag, c + reach < env.count else { continue }
        var best = c, top: Float = 0
        for m in (c - reach)...(c + reach) {
            let rise = env[m] - env[m - lag]
            if rise > top {
                top = rise
                best = m
            }
        }
        hits.append((b, Double(best - c) * Double(hop) / 44.1, top))
    }
    guard hits.count > 32 else { return "" }
    let floor = hits.map(\.peak).sorted()[hits.count * 9 / 10] * 0.25
    let strong = hits.filter { $0.peak >= floor }
    func median(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.sorted()[v.count / 2] }
    let mid = median(strong.map(\.off))
    let near = strong.filter { abs($0.off - mid) <= 15 }.count
    let parts = (0..<12).map { k -> String in
        let chunk = strong.filter { $0.beat * 12 / max(1, t.analysis.beats) == k }.map(\.off)
        return chunk.count < 4 ? "  ." : String(format: "%+4.0f", median(chunk) - mid)
    }.joined(separator: " ")
    return String(format: "   kicks on the grid: %.0f%% within 15 ms (%d hits), through the song in ms: %@", 100 * Double(near) / Double(max(1, strong.count)), strong.count, parts)
}

func analyze(_ paths: [String], grid: Bool = false) {
    for path in paths {
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        let info = isDir.boolValue ? Library.read(url) : TrackInfo(id: url.lastPathComponent, title: url.deletingLastPathComponent().lastPathComponent, artist: "", folder: url.deletingLastPathComponent(), files: [url.lastPathComponent])
        guard let info else {
            print("skip", path)
            continue
        }
        do {
            let t0 = Date()
            let t = try LoadedTrack.load(info)
            print(describe(t), String(format: "  (%.1fs)", Date().timeIntervalSince(t0)))
            if grid { print(tightness(t)) }
        } catch {
            print("FAILED", path, error.localizedDescription)
        }
    }
}

func writeWav(_ path: String, _ l: [Float], _ r: [Float]) {
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(l.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(44100); u32(44100 * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    var pcm = [Int16](repeating: 0, count: l.count * 2)
    for i in 0..<l.count {
        pcm[i * 2] = Int16(max(-1, min(1, l[i])) * 32767)
        pcm[i * 2 + 1] = Int16(max(-1, min(1, r[i])) * 32767)
    }
    pcm.withUnsafeBytes { data.append(contentsOf: $0) }
    try? data.write(to: URL(fileURLWithPath: path))
}

func infoFor(_ path: String) -> TrackInfo? {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
    if isDir.boolValue { return Library.read(url) }
    return TrackInfo(id: url.deletingLastPathComponent().lastPathComponent, title: url.deletingLastPathComponent().lastPathComponent, artist: "", folder: url.deletingLastPathComponent(), files: [url.lastPathComponent])
}

func automix(_ argv: [String]) {
    var paths: [String] = [], script: [(Double, String)] = [], seconds = 120.0, out: String?, skip = 0.0, trace = false, lastTrace = -1.0, every = 4.0
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--at": script.append((Double(argv[i + 1])!, argv[i + 2])); i += 3
        case "--seconds": seconds = Double(argv[i + 1])!; i += 2
        case "--out": out = argv[i + 1]; i += 2
        case "--skip": skip = Double(argv[i + 1])!; i += 2
        case "--trace": trace = true; i += 1
        case "--every": every = Double(argv[i + 1])!; i += 2
        default: paths.append(argv[i]); i += 1
        }
    }
    let session = Session()
    session.loader = { info, done in done(Result { try LoadedTrack.load(info) }) }
    session.voiceLoader = { speech, range, done in done(Speeches.load(speech, range: range)) }
    session.reloadSpeeches()
    var clock = 0.0
    session.log = { print(String(format: "[%7.2fs beat %8.2f] ", clock, session.engine.state.masterBeat) + $0) }
    for p in paths {
        if let info = infoFor(p) { session.enqueue(info) }
    }
    session.mix()
    if skip > 0, let c = session.current, let t = session.decks[c].track {
        session.engine.cue(c, trackBeat: t.beat(atFrame: skip * 44100).rounded())
    }
    let block = 512, total = Int(seconds * 44100)
    var l = [Float](repeating: 0, count: block), r = [Float](repeating: 0, count: block)
    var outL: [Float] = [], outR: [Float] = []
    var done = 0, next = 0, peak: Float = 0, lastSecond = -1
    var rms: [Float] = []
    var acc: Float = 0, accN = 0
    script.sort { $0.0 < $1.0 }
    while done < total {
        clock = Double(done) / 44100
        while next < script.count, script[next].0 <= clock {
            let cmd = script[next].1
            print(String(format: "[%7.2fs] > %@", clock, cmd as NSString))
            if let m = Move(rawValue: cmd) {
                session.perform(m)
            } else if cmd.hasPrefix("stem") {
                let parts = cmd.split(separator: ":")
                session.toggleStem(Int(parts[1])!, Stem(rawValue: Int(parts[2])!)!)
            } else if cmd.hasPrefix("style:") {
                session.setStyle(Technique(rawValue: String(cmd.dropFirst(6))))
            } else if cmd.hasPrefix("word:") {
                let parts = cmd.split(separator: ":").map(String.init)
                if parts.count == 3, let speech = session.speeches.first(where: { $0.id == parts[1] }), let word = speech.words.first(where: { $0.text.lowercased() == parts[2] }) {
                    session.speakWords(speech, from: word.start, to: word.end, label: word.text)
                } else {
                    print("    no such word")
                }
            } else if cmd.hasPrefix("voice:") {
                session.speak(session.speeches.first { $0.id == String(cmd.dropFirst(6)) })
            } else if cmd.hasPrefix("voicegain:") {
                session.voiceGain = Double(cmd.dropFirst(10)) ?? 1.3
            } else if cmd.hasPrefix("fx:") {
                session.setEffect(Effect.allCases.first { $0.label.lowercased() == String(cmd.dropFirst(3)) })
            } else if cmd == "roll:on" {
                session.rollBegin()
            } else if cmd == "roll:off" {
                session.rollEnd()
            } else if cmd == "half" {
                session.scaleLoop(0.5)
            } else if cmd == "auto:off" {
                session.autoMix = false
            } else if cmd == "pause" {
                session.playPause(session.current ?? 0)
            } else if cmd == "fadeend" {
                session.crossfadeEnd()
            } else if cmd.hasPrefix("fade:") {
                session.crossfade(delta: Double(cmd.split(separator: ":")[1]) ?? 0)
            }
            next += 1
        }
        session.tick()
        if trace, let tr = session.transition {
            let st = session.engine.state
            let step = (st.masterBeat / every + 0.02).rounded(.down)
            if step != lastTrace, st.masterBeat >= tr.startBeat - 2 {
                lastTrace = step
                func row(_ d: Int) -> String {
                    let k = st.deck(d)
                    let v = (0..<7).map { k.param(Int32($0)) }
                    return String(format: "%@ vol %.2f voc %.2f drm %.2f bas %.2f mus %.2f flt %+.2f ech %.2f", k.playing != 0 ? "on " : "off", v[0], v[1], v[2], v[3], v[4], v[5], v[6])
                }
                print(String(format: "    %@ p %.3f bpm %6.2f | out: %@%@ | in: %@ pitch %d", tr.label as NSString, tr.progress(atBeat: st.masterBeat), st.masterBpm, row(tr.from),
                             (st.deck(tr.from).looping != 0 ? " loop" : st.deck(tr.from).rolling != 0 ? " roll" : "") as NSString, row(tr.to), session.decks[tr.to].pitch))
            }
        }
        session.engine.render(&l, &r, block)
        for k in 0..<block {
            peak = max(peak, abs(l[k]))
            acc += l[k] * l[k]
        }
        accN += block
        if Int(clock) != lastSecond {
            lastSecond = Int(clock)
            rms.append((acc / Float(max(1, accN))).squareRoot())
            acc = 0
            accN = 0
        }
        if out != nil {
            outL.append(contentsOf: l)
            outR.append(contentsOf: r)
        }
        done += block
    }
    let s = session.engine.state
    print(String(format: "done: peak %.3f load %.3f bpm %.2f current deck %@ queue %d", peak, s.load, s.masterBpm, String(describing: session.current), session.queue.count))
    print("rms per second:", rms.map { String(format: "%.2f", $0) }.joined(separator: " "))
    if let out { writeWav(out, outL, outR) }
}

func scratchtest() {
    let sr = 44100.0, frames = Int(40 * sr)
    let t = be_track_create(1, Int64(frames))!
    let p = be_track_stem(t, 0)!
    for i in 0..<frames {
        let v = Int16(sin(Double(i) * 2 * .pi * 440 / sr) * 12000)
        p[2 * i] = v
        p[2 * i + 1] = v
    }
    func run(_ name: String, speed: Double, hz: Double, jitter: Double) {
        let e = Engine()
        e.load(0, t)
        e.play(0, trackBeat: 16)
        var rates: [Double] = [], level: [Float] = [], next = 0.5, last = 0.5, flip = false, sent = 0.0
        var began = false, moved = 0.0, startBeat = 0.0
        let out = renderMono(e, seconds: 2.6) { time in
            if time >= 0.5, !began {
                began = true
                e.scratchBegin(0)
                startBeat = e.state.deck.0.beat
            }
            while began, time >= next, next < 2.0 {
                let dt = next - last
                if dt > 0 {
                    e.scratchMove(0, frames: speed * dt * sr, seconds: dt)
                    sent += speed * dt * sr
                }
                last = next
                flip.toggle()
                next += (1 + (flip ? jitter : -jitter)) / hz
            }
            if time > 0.9, time < 1.9 { rates.append(e.state.deck.0.rate) }
            if time > 2.3, moved == 0 { moved = (e.state.deck.0.beat - startBeat) * sr * 0.5 }
        }
        for k in stride(from: Int(0.9 * sr), to: Int(1.9 * sr), by: 512) {
            var acc: Float = 0
            for i in k..<(k + 512) { acc += out[i] * out[i] }
            level.append((acc / 512).squareRoot())
        }
        let mean = rates.reduce(0, +) / Double(max(1, rates.count))
        let dev = (rates.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(1, rates.count))).squareRoot()
        let lv = level.reduce(0, +) / Float(max(1, level.count))
        var tail: Float = 0
        for i in Int(2.4 * sr)..<Int(2.55 * sr) { tail = max(tail, abs(out[i])) }
        print(String(format: "%@: rate mean %.3f (asked %.3f), ripple %.1f%% (min %.3f max %.3f), level %.3f, travel %.0f of %.0f frames, level after the finger stops %.4f",
                     name as NSString, mean, speed, 100 * dev / max(0.001, abs(mean)), rates.min() ?? 0, rates.max() ?? 0, lv, moved, sent, tail))
    }
    func wave(_ name: String, strokes: Double, reach: Double) {
        let e = Engine()
        e.load(0, t)
        e.play(0, trackBeat: 16)
        var began = false, next = 0.5, last = 0.5, flip = false
        var heard: [(time: Double, rate: Double)] = []
        func finger(_ time: Double) -> Double { reach * sr * sin(2 * .pi * strokes * (time - 0.5)) }
        _ = renderMono(e, seconds: 2.2) { time in
            if time >= 0.5, !began {
                began = true
                e.scratchBegin(0)
            }
            if time >= 0.45, time < 0.56, !began || heard.isEmpty { }
            while began, time >= next, next < 2.0 {
                if next > last { e.scratchMove(0, frames: finger(next) - finger(last), seconds: next - last) }
                last = next
                flip.toggle()
                next += (1 + (flip ? 0.2 : -0.2)) / 60
            }
            if time > 0.8, time < 1.9 { heard.append((time, e.state.deck.0.rate)) }
        }
        var best = (lag: 0.0, error: Double.infinity)
        for step in 0...40 {
            let lag = Double(step) * 0.002
            var acc = 0.0
            for h in heard {
                let want = reach * 2 * .pi * strokes * cos(2 * .pi * strokes * (h.time - lag - 0.5))
                acc += (h.rate - want) * (h.rate - want)
            }
            let error = (acc / Double(heard.count)).squareRoot()
            if error < best.error { best = (lag, error) }
        }
        let peak = reach * 2 * .pi * strokes
        print(String(format: "%@: record follows the finger %.0f ms behind, speed error %.1f%% of the peak speed (%.2fx)", name as NSString, best.lag * 1000, 100 * best.error / peak, peak))
    }
    wave("baby scratch, 4 strokes a second", strokes: 2, reach: 0.07)
    wave("fast scribble, 12 strokes a second", strokes: 6, reach: 0.03)
    run("finger resting on the record ", speed: 0, hz: 60, jitter: 0)
    run("steady 1.0x at 60 Hz        ", speed: 1.0, hz: 60, jitter: 0)
    run("steady 1.0x, uneven events  ", speed: 1.0, hz: 60, jitter: 0.35)
    run("slow drag 0.25x             ", speed: 0.25, hz: 60, jitter: 0.2)
    run("backwards 1.5x              ", speed: -1.5, hz: 60, jitter: 0.2)
    run("fast 4x at 90 Hz            ", speed: 4.0, hz: 90, jitter: 0.2)
}

func voices() {
    let list = Speeches.scan()
    for s in list {
        guard let raw = Speeches.load(s), let p = be_track_stem(raw, 0) else {
            print(s.id, "cannot be read")
            continue
        }
        let frames = Int(be_track_frames(raw)), win = 2205
        var levels: [Float] = [], peak: Float = 0, i = 0
        while i + win <= frames {
            var acc: Float = 0
            for k in i..<(i + win) {
                let v = (Float(p[2 * k]) + Float(p[2 * k + 1])) / 65536
                acc += v * v
                peak = max(peak, abs(v))
            }
            levels.append((acc / Float(win)).squareRoot())
            i += win
        }
        let loud = levels.sorted().suffix(max(1, levels.count * 6 / 10))
        let active = (loud.reduce(0) { $0 + $1 * $1 } / Float(loud.count)).squareRoot()
        let lead = Double(levels.firstIndex { $0 > 0.02 } ?? 0) * 0.05, tail = Double(levels.count - 1 - (levels.lastIndex { $0 > 0.02 } ?? 0)) * 0.05
        print(String(format: "%-20@ %5.1f s  hit %5.1f  speech rms %.3f  peak %.2f  quiet lead %.2f s  tail %.2f s  %@ · %@", s.id as NSString, s.seconds, s.hit, active, peak, lead, tail, s.speaker as NSString, s.title as NSString))
        be_track_release(raw)
    }
    print("\(list.count) voices in \(Speeches.root.path)")
}

func pairs() {
    let all = Library.scan().compactMap { info in LoadedTrack.cachedAnalysis(info).map { (info, $0) } }
    var smooth = 0, ride = 0, wide = 0, bridge = 0, cut = 0, total = 0
    for (ia, a) in all {
        for (ib, b) in all where ia.id != ib.id {
            total += 1
            let ratio = b.bpm / a.bpm
            if ratio > 1.22 || ratio < 0.82 {
                if ia.hasStems, ib.hasStems, ratio > 0.6, ratio < 1.67 {
                    bridge += 1
                } else {
                    cut += 1
                }
                continue
            }
            let m = Key.match(a.key, b.key)
            let harmonic = min(a.keyStrength, b.keyStrength) >= 0.05 && m.score >= 2 && abs(m.shift) <= 1
            if ratio > 1.11 || ratio < 0.9 {
                wide += 1
            } else if harmonic {
                smooth += 1
            } else {
                ride += 1
            }
        }
    }
    func pct(_ n: Int) -> String { String(format: "%.0f%%", 100 * Double(n) / Double(max(1, total))) }
    print("songs \(all.count), ordered pairs \(total)")
    print("harmonic blend \(pct(smooth)), drum ride / loop / chop \(pct(ride)), tempo ride (11-22% apart) \(pct(wide)), tempo far but bridgeable \(pct(bridge)) (two of three get the drum bridge), only a cut \(pct(cut))")
}

func barChroma(_ t: LoadedTrack, stems: [Int32]) -> [[Float]] {
    let frames = Int(be_track_frames(t.raw)), n = frames / 4
    var x = [Float](repeating: 0, count: n)
    for stem in (t.stems == 4 ? stems : [0]) {
        let p = be_track_stem(t.raw, stem)!
        for i in 0..<n {
            var acc: Float = 0
            for k in 0..<4 { acc += Float(p[(i * 4 + k) * 2]) + Float(p[(i * 4 + k) * 2 + 1]) }
            x[i] += acc / 262144
        }
    }
    let fpb = t.fpb / 4, len = Int(fpb), first = t.analysis.firstBeatFrame / 4, st = t.structure
    let window = (0..<len).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(len))) }
    let coeff = (48..<84).map { Float(2 * cos(2 * Double.pi * 440 * pow(2, (Double($0) - 69) / 12) / 11025)) }
    var out: [[Float]] = []
    for bar in 0..<st.bars {
        var f = [Float](repeating: 0, count: 48)
        for q in 0..<4 {
            let i0 = Int((first + (st.beat(ofBar: bar) + Double(q)) * fpb).rounded())
            guard i0 >= 0, i0 + len <= n else { continue }
            for (k, c) in coeff.enumerated() {
                var s1: Float = 0, s2: Float = 0
                for i in 0..<len {
                    let s0 = x[i0 + i] * window[i] + c * s1 - s2
                    s2 = s1
                    s1 = s0
                }
                f[q * 12 + (48 + k) % 12] += max(0, s1 * s1 + s2 * s2 - c * s1 * s2).squareRoot()
            }
        }
        let norm = f.reduce(0) { $0 + $1 * $1 }.squareRoot()
        out.append(norm > 1e-6 ? f.map { $0 / norm } : f)
    }
    return out
}

func barVoice(_ t: LoadedTrack) -> [[Float]] {
    guard t.stems == 4, let p = be_track_stem(t.raw, 0) else { return [] }
    let frames = Int(be_track_frames(t.raw)), st = t.structure, step = t.fpb / 4
    return (0..<st.bars).map { bar in
        (0..<16).map { k -> Float in
            let i0 = Int(t.analysis.firstBeatFrame + (st.beat(ofBar: bar) * 4 + Double(k)) * step), i1 = i0 + Int(step)
            guard i0 >= 0, i1 <= frames else { return 0 }
            var acc: Float = 0
            for i in stride(from: i0, to: i1, by: 4) { acc += abs(Float(p[i * 2])) }
            return acc / Float(max(1, (i1 - i0) / 4)) / 32768
        }
    }
}

func twin(_ argv: [String]) {
    guard argv.count >= 2, let ia = infoFor(argv[0]), let ib = infoFor(argv[1]), let a = try? LoadedTrack.load(ia), let b = try? LoadedTrack.load(ib) else {
        print("usage: blendtool twin <version folder> <original folder>")
        return
    }
    print(describe(a))
    print(describe(b))
    let va = barVoice(a), vb = barVoice(b)
    func match(_ i: Int, _ j: Int, bars: Int) -> Float {
        var x: [Float] = [], y: [Float] = []
        for d in 0..<bars where i + d < va.count && j + d < vb.count && i + d >= 0 && j + d >= 0 {
            x += va[i + d]
            y += vb[j + d]
        }
        guard x.count >= 16 else { return 0 }
        let mx = x.reduce(0, +) / Float(x.count), my = y.reduce(0, +) / Float(y.count)
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for k in 0..<x.count {
            sxy += (x[k] - mx) * (y[k] - my)
            sxx += (x[k] - mx) * (x[k] - mx)
            syy += (y[k] - my) * (y[k] - my)
        }
        return sxx > 1e-9 && syy > 1e-9 ? sxy / (sxx * syy).squareRoot() : 0
    }
    print("vocal envelope: 2-bar block of \(a.info.title) (\(a.info.artist)) -> best matches in the other version (bar:correlation)")
    var pairs: [(Int, Int)] = []
    var i = 0
    while i + 2 <= va.count {
        let loud = va[i].reduce(0, +) + va[i + 1].reduce(0, +)
        let scored = (0..<max(1, vb.count - 1)).map { ($0, match(i, $0, bars: 2)) }.sorted { $0.1 > $1.1 }
        let top = scored.prefix(4).map { String(format: "%3d:%.2f", $0.0, $0.1) }.joined(separator: "  ")
        print(String(format: "  bar %3d  voice %.2f  ->  %@", i, loud / 32, top as NSString))
        if let best = scored.first, best.1 > 0.8 { pairs.append((i, best.0)) }
        i += 2
    }
    var anchors: [(Int, Int)] = []
    for (x, y) in pairs where anchors.last.map({ y - $0.1 != x - $0.0 }) ?? true { anchors.append((x, y)) }
    print("runs with a constant offset (bar here, bar there):", anchors.map { "[\($0.0), \($0.1)]" }.joined(separator: ", "))
    let ca = barChroma(a, stems: [2, 3]), cb = barChroma(b, stems: [2, 3])
    var voice: [(Int, Float)] = [], harmony: [(Int, Int, Float)] = []
    for d in -24...max(-24, vb.count - 8) {
        let rows = (0..<va.count).filter { $0 + d >= 0 && $0 + d < vb.count }
        guard rows.count >= min(va.count, vb.count) / 2 else { continue }
        voice.append((d, rows.reduce(Float(0)) { $0 + match($1, $1 + d, bars: 1) } / Float(rows.count)))
        for shift in 0..<12 {
            var total: Float = 0
            for x in rows {
                for q in 0..<4 {
                    for k in 0..<12 { total += ca[x][q * 12 + k] * cb[x + d][q * 12 + (k + shift) % 12] }
                }
            }
            harmony.append((d, shift > 6 ? shift - 12 : shift, total / Float(rows.count)))
        }
    }
    print("whole song, best constant offsets by voice:", voice.sorted { $0.1 > $1.1 }.prefix(6).map { String(format: "%+d:%.2f", $0.0, $0.1) }.joined(separator: "  "))
    print("whole song, best offset and semitones by harmony:", harmony.sorted { $0.2 > $1.2 }.prefix(8).map { String(format: "%+d/%+d:%.3f", $0.0, $0.1, $0.2) }.joined(separator: "  "))
    guard argv.count >= 3, let offset = Int(argv[2]) else { return }
    let from = argv.count >= 4 ? Int(argv[3]) ?? 0 : 0, to = argv.count >= 5 ? Int(argv[4]) ?? va.count : va.count
    let bars = (max(0, from)..<min(to, ca.count)).filter { $0 + offset >= 0 && $0 + offset < cb.count }
    let flatA = bars.flatMap { va[$0] }, flatB = bars.flatMap { vb[$0 + offset] }
    var shifts: [(Int, Float)] = []
    for shift in -12...12 {
        var sxy: Float = 0, sxx: Float = 0, syy: Float = 0
        for i in 0..<flatA.count where i + shift >= 0 && i + shift < flatB.count {
            sxy += flatA[i] * flatB[i + shift]
            sxx += flatA[i] * flatA[i]
            syy += flatB[i + shift] * flatB[i + shift]
        }
        shifts.append((shift, sxx > 0 && syy > 0 ? sxy / (sxx * syy).squareRoot() : 0))
    }
    print("bars \(bars.first ?? 0)-\(bars.last ?? 0) at offset \(offset): voice match by shift in quarter beats:", shifts.sorted { $0.1 > $1.1 }.prefix(5).map { String(format: "%+d:%.3f", $0.0, $0.1) }.joined(separator: "  "))
    for shift in 0..<12 {
        var total: Float = 0
        for x in bars {
            for q in 0..<4 {
                for k in 0..<12 { total += ca[x][q * 12 + k] * cb[x + offset][q * 12 + (k + shift) % 12] }
            }
        }
        print(String(format: "bass and music at offset %d bars, other version %+d semitones: %.3f", offset, shift > 6 ? shift - 12 : shift, total / Float(max(1, bars.count))))
    }
}

func touchtest() {
    final class Seen {
        var begins: [Int] = [], ends: [Int] = [], taps: [Int] = []
        var frames = [0.0, 0.0], filter: [Float] = [0, 0]
        var fade = 0.0, fadeEnds = 0
    }
    func make() -> (TouchBoard, Seen) {
        let b = TouchBoard(), s = Seen()
        b.onScratchBegin = { s.begins.append($0) }
        b.onScratchEnd = { s.ends.append($0) }
        b.onScratchMove = { d, f, _ in s.frames[d] += abs(f) }
        b.onFilter = { d, v in s.filter[d] = v }
        b.onFade = { s.fade += $0 }
        b.onFadeEnd = { s.fadeEnds += 1 }
        b.onTap = { s.taps.append($0) }
        return (b, s)
    }
    var failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        if !ok { failed += 1 }
        print((ok ? "PASS  " : "FAIL  ") + name + "  " + detail)
    }
    func slide(_ b: TouchBoard, ids: [String], from: [(Double, Double)], to: [(Double, Double)], steps: Int = 20, t0: Double = 0.02) {
        for k in 1...steps {
            let f = Double(k) / Double(steps)
            b.moved(ids.enumerated().map { i, id in TouchPoint(id: id, x: from[i].0 + (to[i].0 - from[i].0) * f, y: from[i].1 + (to[i].1 - from[i].1) * f) }, time: t0 + Double(k) * 0.016)
        }
    }

    var (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.30, y: 0.08), TouchPoint(id: "b", x: 0.38, y: 0.10)], live: ["a", "b"], time: 0)
    slide(b, ids: ["a", "b"], from: [(0.30, 0.08), (0.38, 0.10)], to: [(0.30, 0.6), (0.38, 0.62)])
    check("two fingers swiping up from the bottom strip sweep the filter", s.filter[0] > 0.5 && s.fade == 0 && s.begins.isEmpty, "filter \(s.filter[0]) fade \(s.fade) scratches \(s.begins)")
    b.ended(["a", "b"], cancelled: false, time: 1)
    check("filter is released when both fingers lift", !b.filtering[0], "")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.46, y: 0.5), TouchPoint(id: "b", x: 0.56, y: 0.52)], live: ["a", "b"], time: 0)
    slide(b, ids: ["a", "b"], from: [(0.46, 0.5), (0.56, 0.52)], to: [(0.46, 0.8), (0.56, 0.82)])
    check("two fingers across the centre line filter one deck, scratch none", s.filter[0] > 0.3 && s.filter[1] == 0 && s.begins.isEmpty, "filter \(s.filter) scratches \(s.begins)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.05, y: 0.08)], live: ["a"], time: 0)
    slide(b, ids: ["a"], from: [(0.05, 0.08)], to: [(0.6, 0.09)])
    b.ended(["a"], cancelled: false, time: 1)
    check("a slide that starts in the corner becomes the crossfader", s.fade > 0.6 && s.fadeEnds == 1 && s.taps.isEmpty, "fade \(s.fade) ends \(s.fadeEnds) taps \(s.taps)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.95, y: 0.05)], live: ["a"], time: 0)
    b.ended(["a"], cancelled: false, time: 0.15)
    check("a quick corner tap plays or pauses that deck", s.taps == [1], "taps \(s.taps)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.95, y: 0.05, resting: true)], live: ["a"], time: 0)
    b.ended(["a"], cancelled: false, time: 0.15)
    check("a corner tap the system flags as resting still counts", s.taps == [1], "taps \(s.taps)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.25, y: 0.6)], live: ["a"], time: 0)
    b.hold("a")
    check("a finger held still stops the record", s.begins == [0], "scratches \(s.begins)")
    b.ended(["a"], cancelled: false, time: 2)
    check("lifting it lets the record go", s.ends == [0], "ends \(s.ends)")

    (b, s) = make()
    b.began([TouchPoint(id: "ghost", x: 0.2, y: 0.5)], live: ["ghost"], time: 0)
    b.hold("ghost")
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.6)], live: ["a"], time: 5)
    slide(b, ids: ["a"], from: [(0.3, 0.6)], to: [(0.2, 0.75)], t0: 5)
    check("a touch that never reported its end does not block the next gesture", s.ends.first == 0 && s.begins == [0, 0] && !b.filtering[0] && s.frames[0] > 1000, "begins \(s.begins) ends \(s.ends) frames \(Int(s.frames[0]))")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.1)], live: ["a"], time: 0)
    slide(b, ids: ["a"], from: [(0.3, 0.1)], to: [(0.31, 0.7)])
    check("one finger moving up out of the strip scratches instead of fading", s.begins == [0] && s.fade == 0 && s.frames[0] > 1000, "begins \(s.begins) fade \(s.fade)")

    (b, s) = make()
    b.began([TouchPoint(id: "palm", x: 0.1, y: 0.5, resting: true)], live: ["palm"], time: 0)
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.6)], live: ["palm", "a"], time: 1)
    slide(b, ids: ["a"], from: [(0.3, 0.6)], to: [(0.2, 0.75)], t0: 1)
    check("a resting palm does not turn a scratch into a filter", s.begins == [0] && !b.filtering[0], "begins \(s.begins) filtering \(b.filtering)")

    (b, s) = make()
    slide(b, ids: ["late"], from: [(0.7, 0.5)], to: [(0.8, 0.7)])
    check("a finger first seen while moving is picked up", s.begins == [1] && s.frames[1] > 1000, "begins \(s.begins)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.25, y: 0.6)], live: ["a"], time: 0)
    b.began([TouchPoint(id: "b", x: 0.75, y: 0.6)], live: ["a", "b"], time: 0.05)
    slide(b, ids: ["a", "b"], from: [(0.25, 0.6), (0.75, 0.6)], to: [(0.2, 0.75), (0.8, 0.75)])
    check("two hands scratch both decks at once", Set(s.begins) == [0, 1] && !b.filtering[0] && !b.filtering[1], "begins \(s.begins)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.4, y: 0.1)], live: ["a"], time: 0)
    slide(b, ids: ["a"], from: [(0.4, 0.1)], to: [(0.7, 0.12)])
    check("a slide along the bottom strip crossfades", s.fade > 0.35 && s.begins.isEmpty, "fade \(s.fade)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.6)], live: ["a"], time: 0)
    slide(b, ids: ["a"], from: [(0.3, 0.6)], to: [(0.2, 0.75)])
    b.began([TouchPoint(id: "palm", x: 0.08, y: 0.4)], live: ["a", "palm"], time: 1.2)
    let before = s.frames[0]
    slide(b, ids: ["a"], from: [(0.2, 0.75)], to: [(0.3, 0.6)], t0: 1.3)
    check("a palm that lands in the middle of a scratch does not turn it into a filter", !b.filtering[0] && s.ends.isEmpty && s.frames[0] > before + 1000, "filtering \(b.filtering) ends \(s.ends)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.5)], live: ["a"], time: 0)
    b.hold("a")
    b.began([TouchPoint(id: "b", x: 0.2, y: 0.5)], live: ["a", "b"], time: 0.3)
    slide(b, ids: ["a", "b"], from: [(0.3, 0.5), (0.2, 0.5)], to: [(0.3, 0.8), (0.2, 0.8)], t0: 0.3)
    check("a second finger joining a still one still gives the filter", b.filtering[0] && s.filter[0] > 0.3 && s.ends == [0], "filter \(s.filter[0]) ends \(s.ends)")

    (b, s) = make()
    b.began([TouchPoint(id: "a", x: 0.3, y: 0.5), TouchPoint(id: "b", x: 0.2, y: 0.5)], live: ["a", "b"], time: 0)
    slide(b, ids: ["a", "b"], from: [(0.3, 0.5), (0.2, 0.5)], to: [(0.3, 0.6), (0.2, 0.6)])
    b.rest(["b"])
    slide(b, ids: ["a"], from: [(0.3, 0.6)], to: [(0.3, 0.8)], t0: 1)
    b.ended(["a"], cancelled: false, time: 2)
    check("a filter finger that goes to rest lets the other one finish the sweep", s.filter[0] > 0.6 && !b.filtering[0], "filter \(s.filter[0]) filtering \(b.filtering)")
    print(failed == 0 ? "touch rules: all passed" : "touch rules: \(failed) FAILED")
}

var args = CommandLine.arguments
if let i = args.firstIndex(of: "--raw") {
    args.remove(at: i)
    LoadedTrack.straightens = false
}
switch args.count > 1 ? args[1] : "" {
case "automix": automix(Array(args.dropFirst(2)))
case "selftest": selftest()
case "analyze": analyze(Array(args.dropFirst(2)))
case "grid": analyze(Array(args.dropFirst(2)), grid: true)
case "library": analyze(Library.scan().map(\.folder.path))
case "pairs": pairs()
case "voices": voices()
case "scratch": scratchtest()
case "touch": touchtest()
case "twin": twin(Array(args.dropFirst(2)))
default: print("usage: blendtool selftest | touch | scratch | pairs | voices | analyze <folder or file>... | grid <folder>... [--raw] | library | automix <folders> [--at <s> <move>] [--trace]")
}
