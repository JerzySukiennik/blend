// Blend app: app-wide state (mode, tutorial, library selection) and the frame hub that drives layer-backed views.
import AppKit
import BlendEngine
import BlendKit
import Observation
import SwiftUI

protocol FrameDriven: AnyObject {
    func frame(_ state: be_state, model: AppModel)
}

struct WordHit: Identifiable {
    let id: String
    let speech: Speech
    let from: Double
    let to: Double
    let before: String
    let phrase: String
    let after: String
    let exact: Bool
}

@Observable
final class AppModel {
    enum Mode {
        case console, library
    }

    let session = Session()
    var mode: Mode = .library
    var tutorial: Int?
    var search = ""
    var selected = 0
    var onlyFits = false
    var showVoices = false
    var wordQuery: String?
    private(set) var wordHits: [WordHit] = []
    var dropTargeted = false

    @ObservationIgnored var audio: AudioOutput?
    @ObservationIgnored var touches: [CGPoint] = []
    @ObservationIgnored var touchAspect: CGFloat = 1.6
    @ObservationIgnored var lastActivity = Date()
    @ObservationIgnored private let listeners = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored var onModeChange: ((Mode) -> Void)?
    @ObservationIgnored var onWake: (() -> Void)?

    static let tutorialSteps = 6

    private func plain(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber || $0 == " " } }

    var filtered: [TrackInfo] {
        let q = plain(search.trimmingCharacters(in: .whitespaces))
        var list = q.isEmpty ? session.library : session.library.filter { plain($0.title).contains(q) || plain($0.artist).contains(q) }
        if onlyFits, let ref = session.mixReference {
            let scored = list.filter { $0.id != ref.id }.map { (info: $0, fit: session.fit($0, to: ref)) }.filter { $0.fit >= 2 }
            list = scored.enumerated().sorted { ($1.element.fit, $0.offset) < ($0.element.fit, $1.offset) }.map(\.element.info)
        }
        return list
    }

    var voices: [Speech] {
        let q = plain(search.trimmingCharacters(in: .whitespaces))
        return q.isEmpty ? session.speeches : session.speeches.filter { plain($0.title).contains(q) || plain($0.speaker).contains(q) || "\($0.year)".contains(q) }
    }

    func toggleFits() {
        onlyFits.toggle()
        selected = 0
    }

    func toggleVoices() {
        showVoices.toggle()
        selected = 0
    }

    func openWordPicker() {
        guard mode == .console else { return }
        if session.speeches.isEmpty { session.reloadSpeeches() }
        withAnimation(Theme.snappy) {
            wordQuery = ""
            wordHits = []
        }
        touch()
    }

    func closeWordPicker() {
        guard wordQuery != nil else { return }
        withAnimation(Theme.snappy) { wordQuery = nil }
    }

    func typeWord(_ text: String) {
        guard let query = wordQuery, query.count < 40 else { return }
        wordQuery = query + text
        refreshWords()
    }

    func eraseWord() {
        guard let query = wordQuery else { return }
        if query.isEmpty {
            closeWordPicker()
        } else {
            wordQuery = String(query.dropLast())
            refreshWords()
        }
    }

    func pickWord(_ index: Int) {
        guard wordQuery != nil, wordHits.indices.contains(index) else { return }
        let hit = wordHits[index]
        session.speakWords(hit.speech, from: hit.from, to: hit.to, label: hit.phrase)
        closeWordPicker()
        wake()
    }

    private func refreshWords() {
        let needles = plain(wordQuery ?? "").split(separator: " ").map(String.init)
        guard !needles.isEmpty else {
            wordHits = []
            return
        }
        var hits: [WordHit] = []
        for speech in session.speeches where speech.words.count >= needles.count {
            let spoken = speech.words.map { plain($0.text) }
            var found: (index: Int, exact: Bool)?
            for i in 0...(spoken.count - needles.count) {
                var matches = true, exact = true
                for (k, needle) in needles.enumerated() where matches {
                    let word = spoken[i + k]
                    if word == needle { continue }
                    if k == needles.count - 1, word.hasPrefix(needle) {
                        exact = false
                    } else {
                        matches = false
                    }
                }
                guard matches else { continue }
                if found == nil || exact { found = (i, exact) }
                if exact { break }
            }
            guard let found else { continue }
            let i = found.index, j = i + needles.count - 1, words = speech.words
            hits.append(WordHit(id: speech.id, speech: speech, from: words[i].start, to: words[j].end,
                                before: words[max(0, i - 3)..<i].map(\.text).joined(separator: " "), phrase: words[i...j].map(\.text).joined(separator: " "),
                                after: words[(j + 1)..<min(words.count, j + 4)].map(\.text).joined(separator: " "), exact: found.exact))
        }
        hits.sort { ($0.exact ? 0 : 1, $0.speech.speaker, $0.id) < ($1.exact ? 0 : 1, $1.speech.speaker, $1.id) }
        wordHits = Array(hits.prefix(5))
    }

    func speakSelected() {
        let list = voices
        guard list.indices.contains(selected) else { return }
        session.speak(list[selected])
        wake()
    }

    func start(silent: Bool = false) {
        session.reloadLibrary()
        session.reloadSpeeches()
        session.analyzeMissing()
        if silent { return }
        audio = AudioOutput(engine: session.engine)
        try? audio?.start()
    }

    func setMode(_ new: Mode) {
        guard mode != new else { return }
        wordQuery = nil
        withAnimation(Theme.spring) { mode = new }
        if new == .library {
            session.reloadLibrary()
            session.reloadSpeeches()
            session.analyzeMissing()
        }
        onModeChange?(new)
        touch()
    }

    func toggleMode() { setMode(mode == .console ? .library : .console) }

    func touch() { lastActivity = Date() }

    func wake() {
        touch()
        onWake?()
    }

    func register(_ view: FrameDriven) { listeners.add(view) }

    func frame() {
        session.tick()
        let state = session.engine.state
        for case let view as FrameDriven in listeners.allObjects { view.frame(state, model: self) }
    }

    var needsFrames: Bool {
        let s = session.engine.state
        if s.deck.0.playing != 0 || s.deck.1.playing != 0 || s.voicePlaying != 0 || session.speaking != nil { return true }
        return Date().timeIntervalSince(lastActivity) < 2.5
    }

    func advanceTutorial(from step: Int) {
        guard tutorial == step else { return }
        let next = step + 1
        withAnimation(Theme.spring) { tutorial = next >= AppModel.tutorialSteps ? nil : next }
        if next >= AppModel.tutorialSteps { UserDefaults.standard.set(true, forKey: "tutorialDone") }
    }

    func beginTutorial() {
        setMode(.console)
        if session.current == nil {
            let picks = session.library.filter(\.hasStems).prefix(2)
            for info in picks where !session.queue.contains(info) { session.enqueue(info) }
        }
        withAnimation(Theme.spring) { tutorial = 0 }
    }

    func enqueueSelected() {
        let list = filtered
        guard list.indices.contains(selected) else { return }
        let info = list[selected]
        if session.queue.contains(info) {
            session.dequeue(info)
        } else {
            session.enqueue(info)
        }
    }
}
