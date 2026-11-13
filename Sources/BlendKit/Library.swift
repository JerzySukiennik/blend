// Blend kit: the song library on disk (folders with stems, cover, metadata, optional twin link to another version of the same song) and file import.
import AVFoundation
import Foundation

public struct Twin: Hashable, Codable {
    public var of: String
    public var map: [[Int]]
    public var back: [[Int]]?
    public var semitones = 0
}

public struct TrackInfo: Identifiable, Hashable, Codable {
    public var id: String
    public var title: String
    public var artist: String
    public var folder: URL
    public var files: [String]
    public var twin: Twin?

    public init(id: String, title: String, artist: String, folder: URL, files: [String], twin: Twin? = nil) {
        self.id = id
        self.title = title
        self.artist = artist
        self.folder = folder
        self.files = files
        self.twin = twin
    }

    public var hasStems: Bool { files.count == 4 }
    public var cover: URL { folder.appendingPathComponent("cover.jpg") }
    public var analysisURL: URL { folder.appendingPathComponent("analysis.json") }
    public var waveURL: URL { folder.appendingPathComponent("wave.bin") }
    public var beatsURL: URL { folder.appendingPathComponent("beats.json") }
}

public enum Library {
    public static let stemFiles = ["vocals.m4a", "drums.m4a", "bass.m4a", "other.m4a"]
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf", "mp4"]

    public static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["BLEND_LIBRARY"], !custom.isEmpty { return URL(fileURLWithPath: custom, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Music/Blend/Library", isDirectory: true)
    }

    public static func scan() -> [TrackInfo] {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        let folders = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [TrackInfo] = []
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            if let info = read(folder) { out.append(info) }
        }
        return out.sorted { ($0.artist.lowercased(), $0.title.lowercased()) < ($1.artist.lowercased(), $1.title.lowercased()) }
    }

    public static func read(_ folder: URL) -> TrackInfo? {
        let fm = FileManager.default
        var files: [String] = []
        if stemFiles.allSatisfy({ fm.fileExists(atPath: folder.appendingPathComponent($0).path) }) {
            files = stemFiles
        } else if let mix = (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted().first(where: { $0.hasPrefix("mix.") }) {
            files = [mix]
        } else {
            return nil
        }
        var title = folder.lastPathComponent, artist = ""
        var twin: Twin?
        if let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            title = meta["title"] as? String ?? title
            artist = meta["artist"] as? String ?? artist
            if let t = meta["twin"] as? [String: Any], let of = t["of"] as? String, let map = t["map"] as? [[Int]] { twin = Twin(of: of, map: map, back: t["back"] as? [[Int]], semitones: t["semitones"] as? Int ?? 0) }
        } else if let dash = title.range(of: " - ") {
            artist = String(title[..<dash.lowerBound])
            title = String(title[dash.upperBound...])
        }
        return TrackInfo(id: folder.lastPathComponent, title: title, artist: artist, folder: folder, files: files, twin: twin)
    }

    public static func importFile(_ url: URL) async -> TrackInfo? {
        guard audioExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let fm = FileManager.default
        var title = url.deletingPathExtension().lastPathComponent, artist = ""
        let asset = AVURLAsset(url: url)
        var artwork: Data?
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                if key == .commonKeyTitle, let v = try? await item.load(.stringValue), !v.isEmpty { title = v }
                if key == .commonKeyArtist, let v = try? await item.load(.stringValue), !v.isEmpty { artist = v }
                if key == .commonKeyArtwork, let v = try? await item.load(.dataValue) { artwork = v }
            }
        }
        if artist.isEmpty, let dash = title.range(of: " - ") {
            artist = String(title[..<dash.lowerBound])
            title = String(title[dash.upperBound...])
        }
        let clean: (String) -> String = { $0.components(separatedBy: CharacterSet(charactersIn: "\\/:*?\"<>|")).joined().trimmingCharacters(in: .whitespaces) }
        let name = artist.isEmpty ? clean(title) : "\(clean(artist)) - \(clean(title))"
        let folder = root.appendingPathComponent(name.isEmpty ? UUID().uuidString : name, isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            let dest = folder.appendingPathComponent("mix.\(url.pathExtension.lowercased())")
            if !fm.fileExists(atPath: dest.path) { try fm.copyItem(at: url, to: dest) }
            let meta: [String: Any] = ["title": title, "artist": artist, "source": url.lastPathComponent]
            try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted]).write(to: folder.appendingPathComponent("meta.json"))
            if let artwork { try? artwork.write(to: folder.appendingPathComponent("cover.jpg")) }
        } catch {
            return nil
        }
        return read(folder)
    }

    public static func remove(_ info: TrackInfo) {
        try? FileManager.default.trashItem(at: info.folder, resultingItemURL: nil)
    }
}
