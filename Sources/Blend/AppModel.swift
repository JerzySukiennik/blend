// Blend app: app-wide state (mode, tutorial, library selection) and the frame hub that drives layer-backed views.
import AppKit
import BlendEngine
import BlendKit
import Observation
import SwiftUI

protocol FrameDriven: AnyObject {
    func frame(_ state: be_state, model: AppModel)
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
    var dropTargeted = false

    @ObservationIgnored var audio: AudioOutput?
    @ObservationIgnored var touches: [CGPoint] = []
    @ObservationIgnored var touchAspect: CGFloat = 1.6
    @ObservationIgnored var lastActivity = Date()
    @ObservationIgnored private let listeners = NSHashTable<AnyObject>.weakObjects()
    @ObservationIgnored var onModeChange: ((Mode) -> Void)?
    @ObservationIgnored var onWake: (() -> Void)?

    static let tutorialSteps = 6

    var filtered: [TrackInfo] {
        func plain(_ s: String) -> String { s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber || $0 == " " } }
        let q = plain(search.trimmingCharacters(in: .whitespaces))
        var list = q.isEmpty ? session.library : session.library.filter { plain($0.title).contains(q) || plain($0.artist).contains(q) }
        if onlyFits, let ref = session.mixReference {
            let scored = list.filter { $0.id != ref.id }.map { (info: $0, fit: session.fit($0, to: ref)) }.filter { $0.fit >= 2 }
            list = scored.enumerated().sorted { ($1.element.fit, $0.offset) < ($0.element.fit, $1.offset) }.map(\.element.info)
        }
        return list
    }

    func toggleFits() {
        onlyFits.toggle()
        selected = 0
    }

    func start(silent: Bool = false) {
        session.reloadLibrary()
        session.analyzeMissing()
        if silent { return }
        audio = AudioOutput(engine: session.engine)
        try? audio?.start()
    }

    func setMode(_ new: Mode) {
        guard mode != new else { return }
        withAnimation(Theme.spring) { mode = new }
        if new == .library {
            session.reloadLibrary()
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
        if s.deck.0.playing != 0 || s.deck.1.playing != 0 { return true }
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
