// Blend app: the console screen (two platters, countdown, mix style and output effect, dual waveform strip, move pills, word picker).
import BlendKit
import SwiftUI

struct ConsoleView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geo in
            let u = min(geo.size.width / 100, geo.size.height / 56)
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 0) {
                    DeckColumn(model: model, deck: 0)
                    CenterColumn(model: model).frame(width: u * 17)
                    DeckColumn(model: model, deck: 1)
                }
                .frame(maxHeight: .infinity)
                WaveStripView(model: model).frame(height: u * 8.6)
                MovesRow(model: model).padding(.top, u * 1.1)
            }
            .padding(.horizontal, u * 2.2)
            .padding(.bottom, u * 1.9)
            .overlay(alignment: .bottomTrailing) {
                if model.wordQuery != nil {
                    WordPicker(model: model)
                        .padding(.trailing, u * 2.2)
                        .padding(.bottom, u * 6.4)
                        .transition(.scale(scale: 0.9, anchor: .bottomTrailing).combined(with: .opacity))
                }
            }
            .environment(\.u, u)
        }
    }
}

struct DeckColumn: View {
    @Environment(\.u) private var u
    let model: AppModel
    let deck: Int

    private var role: String {
        let s = model.session
        guard s.decks[deck].track != nil else { return s.decks[deck].loading != nil ? "LOADING" : "" }
        if let tr = s.transition { return tr.to == deck ? "MIXING IN" : "MIXING OUT" }
        if s.current == deck { return s.paused ? "PAUSED" : "PLAYING" }
        if s.mash != nil { return s.mash == .vocal ? "VOCAL ON TOP" : "BEAT UNDERNEATH" }
        return s.current == nil ? "READY" : "NEXT"
    }

    var body: some View {
        let s = model.session
        let d = s.decks[deck]
        let info = d.track?.info ?? d.loading
        let keys = deck == 0 ? ["1", "2", "3", "4"] : ["7", "8", "9", "0"]
        VStack(spacing: u * 1.05) {
            PlatterView(deck: deck, model: model)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: u * 26.5, maxHeight: u * 26.5)
            VStack(spacing: u * 0.3) {
                Text(role)
                    .font(.system(size: u * 0.78, weight: .bold)).tracking(u * 0.09)
                    .foregroundStyle(s.current == deck && !s.paused ? Theme.text : Theme.dim)
                    .frame(height: u)
                Text(info?.title ?? (deck == 0 ? "Deck A" : "Deck B"))
                    .font(.system(size: u * 1.7, weight: .semibold)).tracking(-u * 0.035)
                    .foregroundStyle(info == nil ? Theme.faint : Theme.text)
                    .lineLimit(1)
                HStack(spacing: u * 0.7) {
                    Text(info?.artist.isEmpty == false ? info!.artist : (info == nil ? "Empty" : "Unknown artist")).foregroundStyle(Theme.dim)
                    if let a = d.track?.analysis {
                        Text(bpmText(a.bpm) + " BPM").fontWeight(.semibold).monospacedDigit()
                        Text(s.keyText(deck)).fontWeight(.semibold)
                    }
                }
                .font(.system(size: u * 1.02))
                .lineLimit(1)
            }
            FilterBar(value: s.filter[deck])
            HStack(spacing: u * 0.45) {
                ForEach(Stem.allCases, id: \.rawValue) { stem in
                    StemChip(stem: stem, on: d.stemOn[stem.rawValue], key: keys[stem.rawValue], present: d.track.map { $0.stems == 4 && $0.structure.stemPresent[stem.rawValue] } ?? false)
                }
            }
            .opacity(d.track == nil ? 0.35 : 1)
        }
        .frame(maxWidth: .infinity)
        .animation(Theme.spring, value: role)
    }
}

struct FilterBar: View {
    @Environment(\.u) private var u
    let value: Float

    var body: some View {
        ZStack {
            Capsule().fill(Theme.line).frame(width: u * 12, height: u * 0.22)
            Circle().fill(Theme.text).frame(width: u * 0.7, height: u * 0.7).offset(x: CGFloat(value) * u * 6)
            HStack {
                Text("LOW").offset(x: -u * 9)
                Text("HIGH").offset(x: u * 9)
            }
            .font(.system(size: u * 0.62, weight: .bold)).tracking(u * 0.08).foregroundStyle(Theme.faint)
        }
        .frame(height: u * 0.7)
        .opacity(value == 0 ? 0 : 1)
        .animation(.easeOut(duration: 0.2), value: value == 0)
    }
}

func bpmText(_ bpm: Double) -> String {
    abs(bpm - bpm.rounded()) < 0.05 ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
}

struct CenterColumn: View {
    @Environment(\.u) private var u
    let model: AppModel

    var body: some View {
        let s = model.session
        let state = centerState(s)
        VStack(spacing: u * 1.3) {
            ZStack {
                Circle().stroke(Theme.line, lineWidth: u * 0.32)
                Circle().trim(from: 0, to: state.ring)
                    .stroke(Theme.text, style: StrokeStyle(lineWidth: u * 0.32, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: state.ring)
                VStack(spacing: u * 0.1) {
                    Text(state.big)
                        .font(.system(size: state.big.count > 2 ? u * 1.9 : u * 3.5, weight: .semibold)).tracking(-u * 0.05)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(state.small).font(.system(size: u * 0.78, weight: .bold)).tracking(u * 0.1).foregroundStyle(Theme.dim)
                }
                .animation(Theme.snappy, value: state.big)
            }
            .frame(width: u * 10.5, height: u * 10.5)
            HStack(spacing: u * 0.7) {
                Text(state.action).font(.system(size: u * 1.05, weight: .bold)).tracking(u * 0.05)
                KeyCap(text: "space", dark: true)
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, u * 1.4)
            .frame(height: u * 3.4)
            .background(Capsule().fill(Theme.text))
            .opacity(state.enabled ? 1 : 0.35)
            VStack(spacing: u * 0.55) {
                HStack(spacing: u * 0.5) {
                    Circle().fill(s.autoMix ? Theme.stems[3] : Theme.faint).frame(width: u * 0.55, height: u * 0.55)
                    Text(s.autoMix ? "AUTO MIX ON" : "AUTO MIX OFF").font(.system(size: u * 0.76, weight: .bold)).tracking(u * 0.08)
                    Text("A").font(.system(size: u * 0.72, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                HStack(spacing: u * 0.5) {
                    Text("STYLE").font(.system(size: u * 0.76, weight: .bold)).tracking(u * 0.08).foregroundStyle(Theme.faint)
                    Text(styleText(s)).font(.system(size: u * 0.76, weight: .bold)).tracking(u * 0.08)
                        .foregroundStyle(s.style == nil ? Theme.dim : Theme.text)
                        .contentTransition(.opacity)
                    Text("M").font(.system(size: u * 0.72, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .animation(Theme.snappy, value: styleText(s))
                HStack(spacing: u * 0.5) {
                    Text("EFFECT").font(.system(size: u * 0.76, weight: .bold)).tracking(u * 0.08).foregroundStyle(Theme.faint)
                    Text(s.effect?.label ?? "OFF").font(.system(size: u * 0.76, weight: .bold)).tracking(u * 0.08)
                        .foregroundStyle(s.effect == nil ? Theme.dim : Theme.text)
                    Text("F").font(.system(size: u * 0.72, weight: .semibold)).foregroundStyle(Theme.faint)
                }
                .animation(Theme.snappy, value: s.effect)
            }
            .foregroundStyle(Theme.dim)
        }
    }

    private func styleText(_ s: Session) -> String {
        if let forced = s.style { return forced.label }
        if let tr = s.transition { return "AUTO · " + tr.label }
        return s.upcoming.map { "AUTO · " + $0.label } ?? "AUTO"
    }

    private func centerState(_ s: Session) -> (big: String, small: String, action: String, ring: CGFloat, enabled: Bool) {
        if s.current == nil {
            if s.cuedDeck != nil { return ("▶", "READY", "PLAY", 0, true) }
            return ("", s.queue.isEmpty ? "ADD A SONG" : "LOADING", "PLAY", 0, false)
        }
        if s.paused { return ("II", "PAUSED", "PLAY", 0, true) }
        if let tr = s.transition {
            if let bars = s.countdownBars, bars > 0, !tr.manual { return ("\(bars)", bars == 1 ? "BAR" : "BARS", tr.label, 0, false) }
            return ("", tr.manual ? "BY HAND" : "MIXING", tr.manual ? "FINISH" : tr.label, CGFloat(s.mixProgress ?? 0), tr.manual)
        }
        if let m = s.mash { return ("", m == .vocal ? "VOCAL MASHUP" : "BEAT SWAP", "MIX", 0, true) }
        if s.nextDeck == nil { return ("", s.queue.isEmpty ? "QUEUE A SONG" : "LOADING", "MIX", 0, false) }
        if let bars = s.countdownBars { return ("\(bars)", bars == 1 ? "BAR" : "BARS", "MIX", 0, true) }
        return ("", "NEXT IS READY", "MIX", 0, true)
    }
}

struct WordPicker: View {
    @Environment(\.u) private var u
    let model: AppModel

    var body: some View {
        let query = model.wordQuery ?? ""
        let hits = model.wordHits
        VStack(alignment: .leading, spacing: u * 0.8) {
            HStack(spacing: u * 0.7) {
                Image(systemName: "quote.bubble.fill").font(.system(size: u * 1.05, weight: .semibold)).foregroundStyle(Theme.dim)
                Text(query.isEmpty ? "Type a word someone says" : query)
                    .font(.system(size: u * 1.25, weight: .semibold))
                    .foregroundStyle(query.isEmpty ? Theme.faint : Theme.text)
                    .lineLimit(1)
                if !query.isEmpty {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.text).frame(width: u * 0.14, height: u * 1.45).padding(.leading, -u * 0.58)
                }
                Spacer(minLength: 0)
                KeyCap(text: "esc")
            }
            .frame(height: u * 2.2)
            Rectangle().fill(Theme.line).frame(height: 1)
            if hits.isEmpty {
                Text(query.isEmpty ? "Try moon, dream, iphone, developers, schtonk" : "Nobody says that")
                    .font(.system(size: u * 1.0, weight: .medium)).foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity, minHeight: u * 3.0, alignment: .leading)
            } else {
                VStack(spacing: u * 0.15) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { index, hit in
                        HStack(spacing: u * 0.9) {
                            KeyCap(text: "\(index + 1)")
                            VStack(alignment: .leading, spacing: u * 0.08) {
                                Text("\(Text(hit.before).foregroundStyle(Theme.faint)) \(Text(hit.phrase).foregroundStyle(Theme.text)) \(Text(hit.after).foregroundStyle(Theme.faint))")
                                    .font(.system(size: u * 1.05, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                                Text("\(hit.speech.speaker) · \(hit.speech.title)").font(.system(size: u * 0.82)).foregroundStyle(Theme.dim).lineLimit(1)
                            }
                            Spacer(minLength: u)
                            Text(String(format: "%.1f s", hit.to - hit.from)).font(.system(size: u * 0.86)).monospacedDigit().foregroundStyle(Theme.dim)
                        }
                        .frame(height: u * 3.0)
                    }
                }
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: u * 0.6) {
                Text("A number drops only these words, on the next beat").foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
                KeyCap(text: "return")
                Text("takes 1").foregroundStyle(Theme.dim)
            }
            .font(.system(size: u * 0.82, weight: .medium))
        }
        .padding(u * 1.3)
        .frame(width: u * 36)
        .background(RoundedRectangle(cornerRadius: u * 1.5, style: .continuous).fill(Theme.bgTop))
        .background(RoundedRectangle(cornerRadius: u * 1.5, style: .continuous).fill(Color.black).shadow(color: .black.opacity(0.55), radius: u * 2.2, y: u * 0.9))
        .overlay(RoundedRectangle(cornerRadius: u * 1.5, style: .continuous).strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        .animation(Theme.snappy, value: hits.map(\.id))
    }
}

struct MovesRow: View {
    @Environment(\.u) private var u
    let model: AppModel

    var body: some View {
        let s = model.session
        HStack(spacing: u * 0.7) {
            ForEach([Move.vocal, .beat, .build, .drop, .loop, .roll, .echo, .brake, .spin, .voice, .word]) { move in
                MovePill(move: move, active: isActive(move, s) || (move == .word && model.wordQuery != nil), pulse: s.flash == move ? s.flashCount : 0)
            }
        }
    }

    private func isActive(_ move: Move, _ s: Session) -> Bool {
        switch move {
        case .vocal: return s.mash == .vocal
        case .beat: return s.mash == .beat
        case .loop: return s.looping
        case .roll: return s.rolling
        case .spin: return s.transition?.style == .spin
        case .build: return s.transition?.label == "BUILD"
        case .echo: return s.transition?.label == "ECHO"
        case .brake: return s.transition?.label == "BRAKE"
        case .voice: return s.speaking != nil
        default: return false
        }
    }
}
