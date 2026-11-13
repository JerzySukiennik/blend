// Blend app: entry point, window, keyboard map, cursor capture for console mode and the frame clock.
import AppKit
import BlendKit
import QuartzCore
import SwiftUI

struct TestOptions {
    var silent = false
    var console = false
    var play = false
    var queue: [String] = []
    var snapshot: String?
    var after = 3.0
    var skip = 0.0
    var keys: [(Double, String)] = []
    var tour: Int?

    init(_ argv: [String]) {
        var i = 1
        while i < argv.count {
            let next = i + 1 < argv.count ? argv[i + 1] : ""
            switch argv[i] {
            case "--silent": silent = true
            case "--console": console = true
            case "--play": play = true
            case "--queue": queue = next.split(separator: "|").map(String.init); i += 1
            case "--snapshot": snapshot = next; i += 1
            case "--after": after = Double(next) ?? 3; i += 1
            case "--skip": skip = Double(next) ?? 0; i += 1
            case "--tour": tour = Int(next); i += 1
            case "--key":
                let parts = next.split(separator: ":")
                if parts.count == 2, let t = Double(parts[0]) { keys.append((t, String(parts[1]))) }
                i += 1
            default: break
            }
            i += 1
        }
    }

    var testing: Bool { snapshot != nil }
}

final class FreeWindow: NSWindow {
    var free = false
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { free ? frameRect : super.constrainFrameRect(frameRect, to: screen) }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = AppModel()
    let options = TestOptions(CommandLine.arguments)
    var pump: Thread?
    var window: FreeWindow!
    var trackpad: TrackpadView!
    var link: CADisplayLink?
    var idle: Timer?
    var monitor: Any?
    var tutorialStarted = false

    func applicationDidFinishLaunching(_ note: Notification) {
        buildMenu()
        let rect = NSRect(x: 0, y: 0, width: 1280, height: 800)
        window = FreeWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Blend"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = true
        window.backgroundColor = NSColor(srgbRed: 0.086, green: 0.086, blue: 0.094, alpha: 1)
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 1040, height: 660)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setFrameAutosaveName("BlendMain")

        let container = NSView(frame: rect)
        let host = NSHostingView(rootView: RootView(model: model))
        host.frame = container.bounds
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        trackpad = TrackpadView(frame: container.bounds)
        trackpad.autoresizingMask = [.width, .height]
        trackpad.model = model
        container.addSubview(trackpad)
        window.contentView = container
        if options.testing {
            window.free = true
            window.setFrame(NSRect(x: -4000, y: -3000, width: 1280, height: 800), display: true)
            window.orderBack(nil)
        } else {
            if !window.setFrameUsingName("BlendMain") { window.center() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        model.onModeChange = { [weak self] mode in self?.capture(mode == .console) }
        model.start(silent: options.silent)
        if options.silent { startPump() }
        runTestScript()

        link = container.displayLink(target: self, selector: #selector(step))
        link?.add(to: .main, forMode: .common)
        idle = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.link?.isPaused == true {
                self.model.frame()
                if self.model.needsFrames { self.link?.isPaused = false }
            }
            self.driveTutorial()
        }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKey(event) ? nil : event
        }
        if !options.testing, !UserDefaults.standard.bool(forKey: "tutorialDone"), !model.session.library.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.startTutorial() }
        }
    }

    @objc func step() {
        model.frame()
        if !model.needsFrames { link?.isPaused = true }
    }

    func wake() {
        model.touch()
        link?.isPaused = false
    }

    @objc func startTutorial() {
        tutorialStarted = false
        model.beginTutorial()
        wake()
    }

    func driveTutorial() {
        guard let step = model.tutorial, step >= 1, !tutorialStarted else { return }
        if model.session.current != nil {
            tutorialStarted = true
        } else if model.session.cuedDeck != nil {
            tutorialStarted = true
            model.session.mix()
            wake()
        }
    }

    func startPump() {
        let engine = model.session.engine
        let thread = Thread {
            var l = [Float](repeating: 0, count: 512), r = [Float](repeating: 0, count: 512)
            let start = Date()
            var rendered = 0.0
            while !Thread.current.isCancelled {
                let due = Date().timeIntervalSince(start)
                while rendered < due {
                    engine.render(&l, &r, 512)
                    rendered += 512.0 / 44100
                }
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
        thread.qualityOfService = .userInitiated
        thread.start()
        pump = thread
    }

    func runTestScript() {
        guard options.testing || options.console || !options.queue.isEmpty else { return }
        let session = model.session
        for id in options.queue {
            if let info = session.library.first(where: { $0.id == id || $0.title == id }) { session.enqueue(info) }
        }
        if options.console { model.mode = .console }
        if options.testing {
            Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.model.frame() }
        }
        if options.play {
            var tries = 0
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] timer in
                guard let self else { return }
                tries += 1
                if session.current == nil, session.cuedDeck != nil {
                    session.mix()
                } else if let c = session.current, let t = session.decks[c].track {
                    if self.options.skip > 0 { session.engine.cue(c, trackBeat: t.beat(atFrame: self.options.skip * 44100).rounded()) }
                    timer.invalidate()
                }
                if tries > 100 { timer.invalidate() }
            }
        }
        if let tour = options.tour {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.model.tutorial = tour
                self?.model.touches = [CGPoint(x: 0.27, y: 0.62), CGPoint(x: 0.7, y: 0.1)]
            }
        }
        for (time, key) in options.keys {
            DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                guard let self else { return }
                if key == "tab" {
                    self.model.mode = self.model.mode == .console ? .library : .console
                } else if key == "space" {
                    session.perform(.mix)
                } else if let move = Move.allCases.first(where: { $0.key.lowercased() == key }) {
                    session.perform(move)
                } else if let n = Int(key) {
                    session.toggleStem(n < 5 && n > 0 ? 0 : 1, Stem(rawValue: n == 0 ? 3 : (n - 1) % 6 % 4) ?? .vocals)
                }
            }
        }
        if let path = options.snapshot {
            DispatchQueue.main.asyncAfter(deadline: .now() + options.after) { [weak self] in
                guard let self, let view = self.window.contentView else { return }
                view.layoutSubtreeIfNeeded()
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                }
                let s = session.engine.state
                print(String(format: "snapshot: beat %.2f bpm %.2f load %.3f playing %d/%d current %@ transition %@", s.masterBeat, s.masterBpm, s.load, s.deck.0.playing, s.deck.1.playing,
                             String(describing: session.current), String(describing: session.transition?.style.rawValue)))
                NSApp.terminate(nil)
            }
        }
    }

    func capture(_ on: Bool) {
        guard !options.testing, on != trackpad.captured else { return }
        trackpad.captured = on
        if on {
            let f = window.frame
            let top = NSScreen.screens.first?.frame.height ?? f.maxY
            CGWarpMouseCursorPosition(CGPoint(x: f.midX, y: top - f.midY))
            CGAssociateMouseAndMouseCursorPosition(0)
            NSCursor.hide()
            window.makeFirstResponder(trackpad)
        } else {
            trackpad.releaseAll()
            CGAssociateMouseAndMouseCursorPosition(1)
            NSCursor.unhide()
        }
        wake()
    }

    func applicationDidResignActive(_ note: Notification) { capture(false) }
    func applicationDidBecomeActive(_ note: Notification) { capture(model.mode == .console) }
    func windowDidResignKey(_ note: Notification) { capture(false) }
    func windowDidBecomeKey(_ note: Notification) { capture(model.mode == .console && NSApp.isActive) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ note: Notification) { capture(false) }

    func handleKey(_ e: NSEvent) -> Bool {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) { return false }
        wake()
        let session = model.session
        if e.keyCode == 48 {
            if !e.isARepeat { model.toggleMode() }
            return true
        }
        if model.mode == .library {
            switch e.keyCode {
            case 53:
                if model.search.isEmpty { return false }
                model.search = ""
                return true
            case 126:
                model.selected = max(0, model.selected - 1)
                return true
            case 125:
                model.selected = min(max(0, model.filtered.count - 1), model.selected + 1)
                return true
            case 36, 76:
                model.enqueueSelected()
                return true
            default:
                return false
            }
        }
        if e.isARepeat { return true }
        if e.keyCode == 53 {
            if model.tutorial != nil {
                withAnimation(Theme.spring) { model.tutorial = nil }
                UserDefaults.standard.set(true, forKey: "tutorialDone")
            } else {
                model.setMode(.library)
            }
            return true
        }
        if e.keyCode == 49 {
            if model.tutorial == 5 { model.advanceTutorial(from: 5) }
            session.perform(.mix)
            return true
        }
        switch e.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "v": session.perform(.vocal)
        case "b": session.perform(.beat)
        case "u": session.perform(.build)
        case "d": session.perform(.drop)
        case "l": session.perform(.loop)
        case "e": session.perform(.echo)
        case "k": session.perform(.brake)
        case "1": session.toggleStem(0, .vocals)
        case "2": session.toggleStem(0, .drums)
        case "3": session.toggleStem(0, .bass)
        case "4": session.toggleStem(0, .music)
        case "7": session.toggleStem(1, .vocals)
        case "8": session.toggleStem(1, .drums)
        case "9": session.toggleStem(1, .bass)
        case "0": session.toggleStem(1, .music)
        case "[": session.scaleLoop(0.5)
        case "]": session.scaleLoop(2)
        case "s":
            if let d = session.nextDeck ?? session.current { session.sync(d) }
        case "a": session.autoMix.toggle()
        case "/", "?": startTutorial()
        default: break
        }
        return true
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Blend", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Blend", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Blend", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        let tour = NSMenuItem(title: "Show the Trackpad Tour", action: #selector(startTutorial), keyEquivalent: "")
        tour.target = self
        helpMenu.addItem(tour)
        helpItem.submenu = helpMenu
        main.addItem(helpItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(delegate.options.testing ? .accessory : .regular)
app.run()
