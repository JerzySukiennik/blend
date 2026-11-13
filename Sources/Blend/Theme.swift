// Blend app: colors, type and the small shared controls (key cap, stem chip, move pill).
import AppKit
import BlendKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.086, green: 0.086, blue: 0.094)
    static let bgTop = Color(red: 0.149, green: 0.149, blue: 0.165)
    static let panel = Color.white.opacity(0.08)
    static let panelStrong = Color.white.opacity(0.13)
    static let line = Color.white.opacity(0.1)
    static let text = Color(white: 0.96)
    static let dim = Color(white: 0.56)
    static let faint = Color(white: 0.39)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.118)

    static let stems: [Color] = [
        Color(red: 1.0, green: 0.773, blue: 0.239),
        Color(red: 0.91, green: 0.91, blue: 0.93),
        Color(red: 0.49, green: 0.478, blue: 1.0),
        Color(red: 0.31, green: 0.82, blue: 0.773)
    ]

    static let stemsNS: [NSColor] = [
        NSColor(srgbRed: 1.0, green: 0.773, blue: 0.239, alpha: 1),
        NSColor(srgbRed: 0.91, green: 0.91, blue: 0.93, alpha: 1),
        NSColor(srgbRed: 0.49, green: 0.478, blue: 1.0, alpha: 1),
        NSColor(srgbRed: 0.31, green: 0.82, blue: 0.773, alpha: 1)
    ]

    static let spring = Animation.spring(response: 0.35, dampingFraction: 1)
    static let snappy = Animation.spring(response: 0.22, dampingFraction: 1)
}

struct Unit: EnvironmentKey {
    static let defaultValue: CGFloat = 12
}

extension EnvironmentValues {
    var u: CGFloat {
        get { self[Unit.self] }
        set { self[Unit.self] = newValue }
    }
}

struct KeyCap: View {
    @Environment(\.u) private var u
    let text: String
    var dark = false

    var body: some View {
        Text(text)
            .font(.system(size: u * 0.82, weight: .semibold))
            .foregroundStyle(dark ? Theme.ink : Theme.dim)
            .padding(.horizontal, u * 0.42)
            .frame(minWidth: u * 1.55, minHeight: u * 1.55)
            .background(RoundedRectangle(cornerRadius: u * 0.4, style: .continuous).fill(dark ? Color.black.opacity(0.1) : Color.white.opacity(0.1)))
    }
}

struct StemChip: View {
    @Environment(\.u) private var u
    let stem: Stem
    let on: Bool
    let key: String
    let present: Bool

    var body: some View {
        HStack(spacing: u * 0.45) {
            Circle().fill(on && present ? Theme.stems[stem.rawValue] : Theme.faint.opacity(0.6)).frame(width: u * 0.62, height: u * 0.62)
            Text(stem.label).font(.system(size: u * 0.86, weight: .semibold)).tracking(u * 0.035)
            Text(key).font(.system(size: u * 0.74, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .foregroundStyle(on && present ? Theme.text : Theme.faint)
        .padding(.horizontal, u * 0.8)
        .frame(height: u * 2.25)
        .background(Capsule().fill(on && present ? Theme.panel : Color.white.opacity(0.035)))
        .animation(Theme.snappy, value: on)
    }
}

struct MovePill: View {
    @Environment(\.u) private var u
    let move: Move
    let active: Bool
    let pulse: Int

    @State private var lit = false

    var body: some View {
        HStack(spacing: u * 0.65) {
            Text(move.label).font(.system(size: u * 1.0, weight: .bold)).tracking(u * 0.05)
            KeyCap(text: move.key, dark: active || lit)
        }
        .foregroundStyle(active || lit ? Theme.ink : Theme.text)
        .frame(maxWidth: .infinity)
        .frame(height: u * 3.6)
        .background(Capsule().fill(active || lit ? Theme.text : Theme.panel))
        .scaleEffect(lit ? 0.97 : 1)
        .animation(Theme.snappy, value: lit)
        .animation(Theme.snappy, value: active)
        .onChange(of: pulse) { _, _ in
            lit = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { lit = false }
        }
        .help(move.help)
    }
}

struct Cover: View {
    let info: TrackInfo?
    let size: CGFloat
    var radius: CGFloat = 8

    var body: some View {
        Group {
            if let info, let image = CoverCache.image(for: info) {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.24), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
                    Text(String((info?.title ?? "").prefix(1))).font(.system(size: size * 0.42, weight: .bold)).foregroundStyle(Theme.dim)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

enum CoverCache {
    private static var cache: [String: NSImage] = [:]

    static func image(for info: TrackInfo) -> NSImage? {
        if let hit = cache[info.id] { return hit }
        guard let image = NSImage(contentsOf: info.cover) else { return nil }
        cache[info.id] = image
        return image
    }

    static func cgImage(for info: TrackInfo) -> CGImage? {
        image(for: info)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
