// blendtool: offline tests for the Blend engine and library (no audio output).
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
    var paths: [String] = [], script: [(Double, String)] = [], seconds = 120.0, out: String?, skip = 0.0, trace = false, lastTrace = -1.0
    var i = 0
    while i < argv.count {
        switch argv[i] {
        case "--at": script.append((Double(argv[i + 1])!, argv[i + 2])); i += 3
        case "--seconds": seconds = Double(argv[i + 1])!; i += 2
        case "--out": out = argv[i + 1]; i += 2
        case "--skip": skip = Double(argv[i + 1])!; i += 2
        case "--trace": trace = true; i += 1
        default: paths.append(argv[i]); i += 1
        }
    }
    let session = Session()
    session.loader = { info, done in done(Result { try LoadedTrack.load(info) }) }
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
            let step = (st.masterBeat / 4).rounded(.down)
            if step != lastTrace, st.masterBeat >= tr.startBeat - 2 {
                lastTrace = step
                func row(_ d: Int) -> String {
                    let k = st.deck(d)
                    let v = (0..<7).map { k.param(Int32($0)) }
                    return String(format: "%@ vol %.2f voc %.2f drm %.2f bas %.2f mus %.2f flt %+.2f ech %.2f", k.playing != 0 ? "on " : "off", v[0], v[1], v[2], v[3], v[4], v[5], v[6])
                }
                print(String(format: "    p %.3f bpm %6.2f | out: %@ | in: %@ pitch %d", tr.progress(atBeat: st.masterBeat), st.masterBpm, row(tr.from), row(tr.to), session.decks[tr.to].pitch))
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
default: print("usage: blendtool selftest | analyze <folder or file>... | grid <folder>... [--raw] | library")
}
