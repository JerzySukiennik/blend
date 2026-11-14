// Blend kit: famous voice clips for the VOICE and WORD moves. One folder per clip with voice.m4a and meta.json (title, speaker, year, seconds, hit, text, words).
import AVFoundation
import BlendEngine
import Foundation

public struct SpokenWord: Hashable {
    public var text: String
    public var start: Double
    public var end: Double
}

public struct Speech: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var speaker: String
    public var year: Int
    public var file: URL
    public var seconds: Double
    public var hit: Double
    public var text: String
    public var words: [SpokenWord]
}

public enum Speeches {
    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["BLEND_SPEECHES"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Blend/Speeches", isDirectory: true)
    }

    public static func scan() -> [Speech] {
        let fm = FileManager.default
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var out: [Speech] = []
        for folder in folders {
            let file = folder.appendingPathComponent("voice.m4a")
            guard fm.fileExists(atPath: file.path),
                  let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = meta["title"] as? String else { continue }
            let seconds = (meta["seconds"] as? NSNumber)?.doubleValue ?? 0
            guard seconds > 0.5 else { continue }
            let hit = (meta["hit"] as? NSNumber)?.doubleValue ?? seconds
            let words = (meta["words"] as? [[String: Any]] ?? []).compactMap { row -> SpokenWord? in
                guard let text = row["w"] as? String, let a = (row["a"] as? NSNumber)?.doubleValue, let b = (row["b"] as? NSNumber)?.doubleValue, b > a else { return nil }
                return SpokenWord(text: text, start: a, end: b)
            }
            out.append(Speech(id: folder.lastPathComponent, title: title, speaker: meta["speaker"] as? String ?? "", year: (meta["year"] as? NSNumber)?.intValue ?? 0,
                              file: file, seconds: seconds, hit: min(seconds, max(0.2, hit)), text: meta["text"] as? String ?? "", words: words))
        }
        return out.sorted { ($0.speaker.lowercased(), $0.title.lowercased()) < ($1.speaker.lowercased(), $1.title.lowercased()) }
    }

    public static let lead = 0.02

    public static func load(_ speech: Speech, range: ClosedRange<Double>? = nil) -> OpaquePointer? {
        guard let file = try? AVAudioFile(forReading: speech.file) else { return nil }
        let frames = Int((Double(file.length) * 44100 / file.processingFormat.sampleRate).rounded(.up))
        guard frames > 2000, let raw = be_track_create(1, Int64(frames)), let pcm = be_track_stem(raw, 0) else { return nil }
        try? LoadedTrack.decode(file, into: pcm, capacity: frames)
        guard let range else { return raw }
        defer { be_track_release(raw) }
        let a = max(0, Int((range.lowerBound - lead) * 44100)), b = min(frames, Int((range.upperBound + 0.04) * 44100))
        guard b - a > 1500, let part = be_track_create(1, Int64(b - a)), let out = be_track_stem(part, 0) else { return nil }
        let count = b - a, fadeIn = 440, fadeOut = 1320
        for i in 0..<count {
            var gain: Float = 1
            if i < fadeIn { gain = Float(i) / Float(fadeIn) }
            if count - i < fadeOut { gain = min(gain, Float(count - i) / Float(fadeOut)) }
            out[2 * i] = Int16(Float(pcm[2 * (a + i)]) * gain)
            out[2 * i + 1] = Int16(Float(pcm[2 * (a + i) + 1]) * gain)
        }
        return part
    }
}
