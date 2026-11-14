// Blend kit: famous voice clips for the VOICE move. One folder per clip with voice.m4a and meta.json (title, speaker, year, seconds, hit).
import AVFoundation
import BlendEngine
import Foundation

public struct Speech: Identifiable, Hashable {
    public var id: String
    public var title: String
    public var speaker: String
    public var year: Int
    public var file: URL
    public var seconds: Double
    public var hit: Double
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
            out.append(Speech(id: folder.lastPathComponent, title: title, speaker: meta["speaker"] as? String ?? "", year: (meta["year"] as? NSNumber)?.intValue ?? 0,
                              file: file, seconds: seconds, hit: min(seconds, max(0.2, hit))))
        }
        return out.sorted { ($0.speaker.lowercased(), $0.title.lowercased()) < ($1.speaker.lowercased(), $1.title.lowercased()) }
    }

    public static func load(_ speech: Speech) -> OpaquePointer? {
        guard let file = try? AVAudioFile(forReading: speech.file) else { return nil }
        let frames = Int((Double(file.length) * 44100 / file.processingFormat.sampleRate).rounded(.up))
        guard frames > 2000, let raw = be_track_create(1, Int64(frames)), let pcm = be_track_stem(raw, 0) else { return nil }
        try? LoadedTrack.decode(file, into: pcm, capacity: frames)
        return raw
    }
}
