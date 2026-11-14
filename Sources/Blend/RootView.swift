// Blend app: window chrome (top bar, mode switch), hint toast and the first-run tutorial overlay.
import BlendKit
import SwiftUI

struct RootView: View {
    let model: AppModel

    var body: some View {
        ZStack {
            RadialGradient(colors: [Theme.bgTop, Theme.bg], center: .top, startRadius: 0, endRadius: 900).ignoresSafeArea()
            VStack(spacing: 0) {
                TopBar(model: model)
                ZStack {
                    if model.mode == .console {
                        ConsoleView(model: model).transition(.opacity.combined(with: .scale(scale: 0.985)))
                    } else {
                        LibraryView(model: model).transition(.opacity.combined(with: .scale(scale: 0.985)))
                    }
                }
            }
            if let hint = model.session.hint {
                VStack {
                    Spacer()
                    Text(hint)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .frame(height: 38)
                        .background(Capsule().fill(Theme.text))
                        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                        .padding(.bottom, 110)
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if let step = model.tutorial {
                TutorialOverlay(model: model, step: step).transition(.opacity)
            }
        }
        .foregroundStyle(Theme.text)
        .animation(Theme.spring, value: model.session.hint)
        .ignoresSafeArea()
    }
}

struct TopBar: View {
    let model: AppModel

    var body: some View {
        let session = model.session
        ZStack {
            Text("Blend").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.dim)
            HStack(spacing: 10) {
                Spacer()
                if model.mode == .console, !session.queue.isEmpty {
                    Text("Up next").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.dim)
                    ForEach(session.queue.prefix(3)) { info in
                        Cover(info: info, size: 26, radius: 6)
                    }
                }
                HStack(spacing: 3) {
                    segment("Console", on: model.mode == .console)
                    segment("Library", on: model.mode == .library)
                    Text("tab").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.faint)
                        .padding(.horizontal, 6).frame(height: 18)
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.faint.opacity(0.7)))
                        .padding(.horizontal, 6)
                }
                .padding(3)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.panel))
                .onTapGesture { model.toggleMode() }
            }
            .padding(.trailing, 18)
        }
        .frame(height: 52)
    }

    private func segment(_ title: String, on: Bool) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(on ? Theme.ink : Theme.dim)
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.text : Color.clear))
    }
}

struct TutorialOverlay: View {
    let model: AppModel
    let step: Int

    private static let steps: [(title: String, body: String, highlight: Int)] = [
        ("Rest a finger on the trackpad", "The trackpad is your console now. Tab gives the cursor back whenever you want it.", 0),
        ("Spin the left half like a record", "One finger grabs Deck A just like vinyl. The right half is Deck B.", 1),
        ("Slide two fingers up or down on a deck", "That sweeps a filter over the song. Lift your fingers and it springs back.", 2),
        ("Slide along the bottom edge", "The strip blends this song into the next one. Slide back to undo it.", 3),
        ("Tap a bottom corner", "The left corner plays or pauses Deck A, the right corner Deck B.", 4),
        ("Now the keys", "Space mixes into the next song and M picks how. N switches at the next good moment, F changes the output effect, T drops a famous voice over the mix, W lets you type a word and drop only that word, V B U D L R E K X fire the moves. The Touch Bar has the same switch, effects and voice. Press space to finish.", 0)
    ]

    var body: some View {
        let s = Self.steps[min(step, Self.steps.count - 1)]
        ZStack {
            Color.black.opacity(0.62).ignoresSafeArea()
            VStack(spacing: 22) {
                TrackpadMapView(model: model, highlight: s.highlight)
                    .frame(width: 440, height: 275)
                VStack(spacing: 8) {
                    Text(s.title).font(.system(size: 24, weight: .bold)).tracking(-0.4).multilineTextAlignment(.center)
                    Text(s.body).font(.system(size: 14.5)).foregroundStyle(Theme.dim).multilineTextAlignment(.center).lineSpacing(3).frame(maxWidth: 420)
                }
                .id(step)
                .transition(.opacity.combined(with: .offset(y: 8)))
                HStack(spacing: 7) {
                    ForEach(0..<Self.steps.count, id: \.self) { i in
                        Capsule().fill(i == step ? Theme.text : Theme.faint.opacity(0.5)).frame(width: i == step ? 20 : 7, height: 7)
                    }
                }
                Text("esc skips the tour").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            .padding(34)
            .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color(red: 0.13, green: 0.13, blue: 0.14)))
            .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        }
        .animation(Theme.spring, value: step)
    }
}
