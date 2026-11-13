// Blend kit: decoding a library track into engine memory, cached analysis, musical structure (bars, drops, vocal phrases) and key maths.
import AVFoundation
import Accelerate
import BlendEngine
import Foundation

public struct Analysis: Codable {
    public static let currentVersion = 9

    public var version = Analysis.currentVersion
    public var bpm: Double
    public var firstBeatFrame: Double
    public var barPhase: Int
    public var phrasePhase: Int
    public var key: Int
    public var keyStrength: Float
    public var gain: Float
    public var confidence: Float
    public var beats: Int
    public var frames: Int
    public var energy: [Float]
    public var beatShift = 0
    public var straightened = false

    public var seconds: Double { Double(frames) / 44100 }
    public var keyName: String { Key.name(key) }
}

public enum Key {
    static let names = ["C", "D♭", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]

    public static func name(_ key: Int) -> String {
        guard key >= 0, key < 24 else { return "?" }
        return names[key % 12] + (key >= 12 ? "m" : "")
    }

    static func related(_ a: Int, _ b: Int) -> Int {
        if a == b { return 3 }
        let am = a >= 12, bm = b >= 12, ar = a % 12, br = b % 12
        if am != bm {
            let majorRoot = am ? br : ar, minorRoot = am ? ar : br
            return (minorRoot + 3) % 12 == majorRoot ? 3 : 0
        }
        let d = (br - ar + 12) % 12
        return (d == 7 || d == 5) ? 2 : 0
    }

    public static func match(_ a: Int, _ b: Int) -> (score: Int, shift: Int) {
        var best = (score: 0, shift: 0)
        for shift in [0, 1, -1, 2, -2] {
            let moved = (b % 12 + shift + 12) % 12 + (b >= 12 ? 12 : 0)
            let r = related(a, moved)
            let score = r == 0 ? 0 : max(1, r - abs(shift))
            if score > best.score { best = (score, shift) }
        }
        return best
    }
}

public struct Structure {
    public let bars: Int
    public let barPhase: Int
    public let phrasePhase: Int
    public let level: [[Float]]
    public let intensity: [Float]
    public let total: [Float]
    public let stemPresent: [Bool]
    public let drops: [Int]
    public let vocalStarts: [Int]
    public let firstFull: Int
    public let lastStrong: Int
    public let firstSound: Int
    public let anchors: [Int]

    public func beat(ofBar bar: Int) -> Double { Double(barPhase + bar * 4) }
    public func bar(atBeat beat: Double) -> Int { Int(floor((beat - Double(barPhase)) / 4)) }
    public func isPhrase(_ bar: Int, every n: Int = 8) -> Bool {
        let anchor = anchors.last { $0 <= bar } ?? anchors.first ?? phrasePhase
        return ((bar - anchor) % n + n) % n == 0
    }

    public func phraseStart(atOrBefore bar: Int, every n: Int = 8) -> Int {
        var b = bar
        while b > 0 && !isPhrase(b, every: n) { b -= 1 }
        return max(0, b)
    }

    public var startBar: Int {
        var b = firstSound
        while !isPhrase(b, every: 4) { b -= 1 }
        return b
    }

    public func nextDrop(afterBar bar: Int) -> Int? { drops.first { $0 > bar } ?? drops.first }

    init(_ a: Analysis, stems: Int) {
        let phase = ((a.barPhase + a.beatShift) % 4 + 4) % 4
        barPhase = phase
        let count = max(0, (a.beats - phase) / 4)
        bars = count
        var raw = [[Float]](repeating: [Float](repeating: 0, count: count), count: 4)
        for bar in 0..<count {
            for s in 0..<4 {
                var acc: Float = 0
                for q in 0..<4 {
                    let i = (phase + bar * 4 + q) * 4 + s
                    if i < a.energy.count { acc += a.energy[i] }
                }
                raw[s][bar] = acc / 4
            }
        }
        var tot = [Float](repeating: 0, count: count)
        for bar in 0..<count {
            var acc: Float = 0
            for s in 0..<4 { acc += raw[s][bar] * raw[s][bar] }
            tot[bar] = acc.squareRoot()
        }
        func percentile(_ v: [Float], _ p: Double) -> Float {
            guard !v.isEmpty else { return 0 }
            let sorted = v.sorted()
            return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
        }
        let totalRef = max(1e-5, percentile(tot, 0.9))
        var lv = raw, present = [Bool](repeating: false, count: 4)
        for s in 0..<4 {
            let ref = percentile(raw[s], 0.9)
            present[s] = s < stems && ref > totalRef * 0.06
            for bar in 0..<count { lv[s][bar] = present[s] ? min(1.5, raw[s][bar] / max(1e-5, ref)) : 0 }
        }
        level = lv
        stemPresent = present
        total = tot.map { min(1.5, $0 / totalRef) }
        let full = stems == 4 && present[1] && present[2]
        var inten = [Float](repeating: 0, count: count)
        for bar in 0..<count { inten[bar] = full ? min(1, 0.5 * (lv[1][bar] + lv[2][bar])) : min(1, total[bar]) }
        intensity = inten

        var found: [Int] = []
        let high: Float = full ? 0.62 : 0.8, low: Float = full ? 0.45 : 0.6
        for bar in 0..<count where inten[bar] >= high {
            let after = inten[bar..<min(count, bar + 4)]
            guard after.reduce(0, +) / Float(after.count) >= high - 0.05 else { continue }
            if bar == 0 {
                found.append(0)
            } else {
                let before = inten[max(0, bar - 2)..<bar]
                if before.reduce(0, +) / Float(before.count) < low { found.append(bar) }
            }
        }
        var cleaned: [Int] = []
        for d in found where cleaned.last.map({ d - $0 >= 8 }) ?? true { cleaned.append(d) }
        drops = cleaned
        var sustained = cleaned.first ?? 0
        for bar in 0..<count where inten[bar] >= high {
            let after = inten[bar..<min(count, bar + 4)]
            if after.reduce(0, +) / Float(after.count) >= high - 0.05 {
                sustained = bar
                break
            }
        }
        firstFull = sustained

        var vs: [Int] = []
        if present[0] {
            for bar in 0..<count where lv[0][bar] > 0.4 {
                let before = bar == 0 ? 0 : lv[0][max(0, bar - 2)..<bar].max() ?? 0
                if before < 0.22 && (vs.last.map { bar - $0 >= 4 } ?? true) { vs.append(bar) }
            }
        }
        vocalStarts = vs
        lastStrong = total.lastIndex { $0 > 0.3 } ?? max(0, count - 1)
        firstSound = total.firstIndex { $0 > 0.12 } ?? 0

        var score = [Float](repeating: 0, count: 8)
        if count > 1 {
            for bar in 1..<count {
                var d = abs(inten[bar] - inten[bar - 1])
                d += 0.5 * abs(lv[0][bar] - lv[0][bar - 1]) + 0.5 * abs(lv[3][bar] - lv[3][bar - 1])
                score[bar % 8] += d
            }
        }
        for d in cleaned where d > 0 { score[d % 8] += 2 }
        score[((a.phrasePhase % 8) + 8) % 8] += 0.5
        var four = 0
        for i in 1..<4 where score[i] + score[i + 4] > score[four] + score[four + 4] { four = i }
        phrasePhase = score[four + 4] > score[four] ? four + 4 : four

        var marks = Set(cleaned)
        if count > 4 {
            for bar in 2..<(count - 1) {
                let before = (inten[bar - 2] + inten[bar - 1]) / 2, after = (inten[bar] + inten[bar + 1]) / 2
                if before >= high && after < low && inten[bar - 1] >= high { marks.insert(bar) }
            }
        }
        var ordered: [Int] = []
        for m in marks.sorted() where ordered.last.map({ m - $0 >= 4 }) ?? true { ordered.append(m) }
        anchors = ordered
    }
}

public final class LoadedTrack {
    public let info: TrackInfo
    public let raw: OpaquePointer
    public let analysis: Analysis
    public let structure: Structure
    public let wave: [UInt8]
    public let warp: be_warp
    public static let wavePoints = 120.0
    public static var straightens = true

    public var stems: Int { info.files.count }
    public var fpb: Double { 44100 * 60 / analysis.bpm }
    public func beat(atFrame frame: Double) -> Double { (frame - analysis.firstBeatFrame) / fpb }

    init(info: TrackInfo, raw: OpaquePointer, analysis: Analysis, wave: [UInt8], warp: be_warp) {
        self.info = info
        self.raw = raw
        self.analysis = analysis
        self.wave = wave
        self.warp = warp
        structure = Structure(analysis, stems: info.files.count)
    }

    deinit { be_track_release(raw) }

    public static func cachedAnalysis(_ info: TrackInfo) -> Analysis? {
        guard let data = try? Data(contentsOf: info.analysisURL), let a = try? JSONDecoder().decode(Analysis.self, from: data), a.version == Analysis.currentVersion else { return nil }
        return a
    }

    public static func load(_ info: TrackInfo) throws -> LoadedTrack {
        let urls = info.files.map { info.folder.appendingPathComponent($0) }
        let files = try urls.map { try AVAudioFile(forReading: $0) }
        let frames = files.map { Int((Double($0.length) * 44100 / $0.processingFormat.sampleRate).rounded(.up)) }.max() ?? 0
        guard frames > 44100, let raw = be_track_create(Int32(files.count), Int64(frames)) else { throw NSError(domain: "Blend", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not read \(info.title)"]) }
        for (i, file) in files.enumerated() {
            try decode(file, into: be_track_stem(raw, Int32(i))!, capacity: frames)
        }
        var beats: [Double] = [], downbeats: [Double] = []
        if let data = try? Data(contentsOf: info.beatsURL), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            beats = (json["beats"] as? [NSNumber])?.map(\.doubleValue) ?? []
            downbeats = (json["downbeats"] as? [NSNumber])?.map(\.doubleValue) ?? []
        }
        var warp = be_warp()
        var analysis: Analysis
        var fresh = false
        if straightens, let cached = cachedAnalysis(info), cached.frames == frames {
            analysis = cached
            if cached.straightened { be_track_straighten(raw, &beats, Int32(beats.count), &downbeats, Int32(downbeats.count), 0, &warp) }
        } else {
            if straightens { be_track_straighten(raw, &beats, Int32(beats.count), &downbeats, Int32(downbeats.count), 1, &warp) }
            analysis = try analyze(info, raw: raw, frames: frames, beats: beats, downbeats: downbeats)
            analysis.straightened = warp.applied == 1
            fresh = true
            if straightens, let data = try? JSONEncoder().encode(analysis) { try? data.write(to: info.analysisURL) }
        }
        be_track_set_grid(raw, analysis.bpm, analysis.firstBeatFrame)
        be_track_set_gain(raw, analysis.gain)
        var wave: [UInt8]
        let expected = Int(Double(frames) / 44100 * wavePoints) * 4
        if !fresh, let data = try? Data(contentsOf: info.waveURL), data.count == expected {
            wave = [UInt8](data)
        } else {
            wave = [UInt8](repeating: 0, count: expected)
            let n = be_waveform(raw, wavePoints, &wave, Int32(expected / 4))
            wave.removeLast(wave.count - Int(n) * 4)
            if straightens { try? Data(wave).write(to: info.waveURL) }
        }
        return LoadedTrack(info: info, raw: raw, analysis: analysis, wave: wave, warp: warp)
    }

    static func analyze(_ info: TrackInfo, raw: OpaquePointer, frames: Int, beats: [Double], downbeats: [Double]) throws -> Analysis {
        var res = be_analysis()
        guard be_analyze(raw, beats, Int32(beats.count), downbeats, Int32(downbeats.count), &res) == 1 else {
            throw NSError(domain: "Blend", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not find the beat in \(info.title)"])
        }
        var energy = [Float](repeating: 0, count: Int(res.beatCount) * 4)
        let n = be_beat_energy(raw, res.bpm, res.firstBeatFrame, &energy, res.beatCount)
        energy.removeLast(energy.count - Int(n) * 4)
        return Analysis(bpm: res.bpm, firstBeatFrame: res.firstBeatFrame, barPhase: Int(res.barPhase), phrasePhase: Int(res.phrasePhase), key: Int(res.key), keyStrength: res.keyStrength,
                        gain: res.gain, confidence: res.gridConfidence, beats: Int(n), frames: frames, energy: energy)
    }

    static func decode(_ file: AVAudioFile, into dst: UnsafeMutablePointer<Int16>, capacity: Int) throws {
        let inFmt = file.processingFormat
        if inFmt.sampleRate == 44100, inFmt.channelCount <= 2, inFmt.commonFormat == .pcmFormatFloat32, !inFmt.isInterleaved {
            guard let buf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 1 << 16) else { return }
            var scratch = [Float](repeating: 0, count: 1 << 16)
            var written = 0
            var scale: Float = 32767, lo: Float = -32767, hi: Float = 32767
            while file.framePosition < file.length, written < capacity {
                try file.read(into: buf)
                let n = min(Int(buf.frameLength), capacity - written)
                if n == 0 { break }
                guard let ch = buf.floatChannelData else { break }
                for c in 0..<2 {
                    let src = ch[min(c, Int(inFmt.channelCount) - 1)]
                    vDSP_vsmul(src, 1, &scale, &scratch, 1, vDSP_Length(n))
                    vDSP_vclip(scratch, 1, &lo, &hi, &scratch, 1, vDSP_Length(n))
                    vDSP_vfix16(scratch, 1, dst + written * 2 + c, 2, vDSP_Length(n))
                }
                written += n
            }
            return
        }
        guard let outFmt = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true),
              let conv = AVAudioConverter(from: inFmt, to: outFmt),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFmt, frameCapacity: 1 << 15),
              let outBuf = AVAudioPCMBuffer(pcmFormat: outFmt, frameCapacity: 1 << 15) else { return }
        var written = 0, finished = false
        while written < capacity {
            var err: NSError?
            let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
                if finished || file.framePosition >= file.length {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: inBuf)
                    outStatus.pointee = .haveData
                    return inBuf
                } catch {
                    finished = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }
            let n = min(Int(outBuf.frameLength), capacity - written)
            if n > 0, let src = outBuf.int16ChannelData {
                memcpy(dst + written * 2, src[0], n * 2 * MemoryLayout<Int16>.size)
                written += n
            }
            if status == .endOfStream || status == .error || n == 0 { break }
        }
    }
}
