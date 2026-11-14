// Blend app: the Touch Bar. Quick switch, output effects, mix style picker, hold-to-roll and a beat counter, built from plain AppKit controls.
import AppKit
import BlendEngine
import BlendKit

extension NSTouchBarItem.Identifier {
    static let blendSwitch = NSTouchBarItem.Identifier("fun.gzowo.blend.switch")
    static let blendEffects = NSTouchBarItem.Identifier("fun.gzowo.blend.effects")
    static let blendStyle = NSTouchBarItem.Identifier("fun.gzowo.blend.style")
    static let blendStyleList = NSTouchBarItem.Identifier("fun.gzowo.blend.styleList")
    static let blendRoll = NSTouchBarItem.Identifier("fun.gzowo.blend.roll")
    static let blendBeat = NSTouchBarItem.Identifier("fun.gzowo.blend.beat")
}

final class HoldView: NSView {
    var title = "ROLL"
    var lit = false {
        didSet { if lit != oldValue { needsDisplay = true } }
    }
    var onDown: (() -> Void)?
    var onUp: (() -> Void)?
    private var finger: NSObjectProtocol?

    override init(frame: NSRect) {
        super.init(frame: frame)
        allowedTouchTypes = [.direct]
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 62, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        (lit ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.22, alpha: 1)).setFill()
        box.fill()
        let text = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold), .foregroundColor: lit ? NSColor.black : NSColor.white])
        let size = text.size()
        text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2))
    }

    override func touchesBegan(with event: NSEvent) {
        guard finger == nil, let touch = event.touches(matching: .began, in: self).first else { return }
        finger = touch.identity
        lit = true
        onDown?()
    }

    override func touchesEnded(with event: NSEvent) { release(event) }
    override func touchesCancelled(with event: NSEvent) { release(event) }

    private func release(_ event: NSEvent) {
        guard let finger, event.touches(matching: [.ended, .cancelled], in: self).contains(where: { $0.identity.isEqual(finger) }) else { return }
        self.finger = nil
        lit = false
        onUp?()
    }
}

final class BeatView: NSView {
    var beat = -1 {
        didSet { if beat != oldValue { needsDisplay = true } }
    }
    var note = "" {
        didSet { if note != oldValue { needsDisplay = true } }
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 84, height: 30) }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<4 {
            let on = i == beat
            let size: CGFloat = on ? 9 : 6
            let dot = NSRect(x: 4 + CGFloat(i) * 13 + (9 - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
            (on ? NSColor.white : NSColor(white: 0.36, alpha: 1)).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        guard !note.isEmpty else { return }
        let text = NSAttributedString(string: note, attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor(white: 0.62, alpha: 1)])
        text.draw(at: NSPoint(x: 58, y: (bounds.height - text.size().height) / 2))
    }
}

final class ConsoleBar: NSObject, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate, FrameDriven {
    private let model: AppModel
    private var switchButton: NSButton?
    private var effects: NSSegmentedControl?
    private var styleItem: NSPopoverTouchBarItem?
    private var styleList: NSScrubber?
    private var roll: HoldView?
    private var beat: BeatView?
    private var shownSwitch = ""
    private var shownStyle = ""
    private let styles: [Technique?] = [nil] + Technique.allCases.map { $0 }

    init(model: AppModel) {
        self.model = model
        super.init()
        model.register(self)
    }

    func make() -> NSTouchBar {
        let bar = NSTouchBar()
        bar.delegate = self
        bar.defaultItemIdentifiers = [.blendSwitch, .fixedSpaceSmall, .blendEffects, .fixedSpaceSmall, .blendStyle, .blendRoll, .flexibleSpace, .blendBeat]
        return bar
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .blendSwitch:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let button = NSButton(title: "SWITCH", target: self, action: #selector(quick))
            button.widthAnchor.constraint(equalToConstant: 88).isActive = true
            item.view = button
            switchButton = button
            shownSwitch = ""
            refresh()
            return item
        case .blendEffects:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let control = NSSegmentedControl(labels: Effect.allCases.map(\.label), trackingMode: .selectAny, target: self, action: #selector(pickEffect(_:)))
            for i in 0..<control.segmentCount { control.setWidth(52, forSegment: i) }
            item.view = control
            effects = control
            refresh()
            return item
        case .blendStyle:
            let item = NSPopoverTouchBarItem(identifier: identifier)
            item.collapsedRepresentationLabel = "STYLE AUTO"
            item.showsCloseButton = true
            let inner = NSTouchBar()
            inner.delegate = self
            inner.defaultItemIdentifiers = [.blendStyleList]
            item.popoverTouchBar = inner
            styleItem = item
            shownStyle = ""
            refresh()
            return item
        case .blendStyleList:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber()
            scrubber.register(NSScrubberTextItemView.self, forItemIdentifier: NSUserInterfaceItemIdentifier("style"))
            scrubber.scrubberLayout = NSScrubberProportionalLayout(numberOfVisibleItems: 7)
            scrubber.mode = .free
            scrubber.selectionBackgroundStyle = .roundedBackground
            scrubber.dataSource = self
            scrubber.delegate = self
            scrubber.selectedIndex = styles.firstIndex { $0 == model.session.style } ?? 0
            item.view = scrubber
            styleList = scrubber
            return item
        case .blendRoll:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = HoldView(frame: NSRect(x: 0, y: 0, width: 62, height: 30))
            view.onDown = { [weak self] in
                self?.model.session.rollBegin()
                self?.model.wake()
            }
            view.onUp = { [weak self] in
                self?.model.session.rollEnd()
                self?.model.wake()
            }
            item.view = view
            roll = view
            return item
        case .blendBeat:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let view = BeatView(frame: NSRect(x: 0, y: 0, width: 84, height: 30))
            item.view = view
            beat = view
            refresh()
            return item
        default:
            return nil
        }
    }

    func numberOfItems(for scrubber: NSScrubber) -> Int { styles.count }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let view = scrubber.makeItem(withIdentifier: NSUserInterfaceItemIdentifier("style"), owner: nil) as? NSScrubberTextItemView ?? NSScrubberTextItemView()
        view.title = styles[index]?.label ?? "AUTO"
        return view
    }

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        guard styles.indices.contains(selectedIndex), styles[selectedIndex] != model.session.style else { return }
        model.session.setStyle(styles[selectedIndex])
        styleItem?.dismissPopover(nil)
        model.wake()
        refresh()
    }

    @objc private func quick() {
        model.session.perform(.quick)
        model.wake()
        refresh()
    }

    @objc private func pickEffect(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard Effect.allCases.indices.contains(index) else { return }
        model.session.toggleEffect(Effect.allCases[index])
        model.wake()
        refresh()
    }

    func frame(_ state: be_state, model: AppModel) { refresh() }

    func showStyles() { styleItem?.showPopover(nil) }

    func snapshot(to path: String) -> String {
        guard let root = (styleList?.window ?? switchButton?.window)?.contentView, let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds) else { return "touch bar is not on screen" }
        root.cacheDisplay(in: root.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        var parts: [String] = []
        for view in [switchButton as NSView?, effects, roll, beat] {
            if let view { parts.append("\(Int(view.convert(view.bounds, to: nil).minX))-\(Int(view.convert(view.bounds, to: nil).maxX))") }
        }
        return "touch bar \(Int(root.bounds.width))x\(Int(root.bounds.height)) pt, items at " + parts.joined(separator: ", ")
    }

    func refresh() {
        let s = model.session
        var title = "SWITCH"
        if let tr = s.transition, tr.name == "SWITCH" { title = (s.countdownBars ?? 0) > 0 ? "IN \(s.countdownBars ?? 0)" : "NOW" }
        let ready = s.nextDeck != nil && s.transition == nil && s.mash == nil && s.current != nil && !s.paused
        let key = title + (ready ? "+" : "-")
        if key != shownSwitch, let button = switchButton {
            shownSwitch = key
            let bright = ready || title != "SWITCH"
            button.attributedTitle = NSAttributedString(string: title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: bright ? NSColor.black : NSColor(white: 0.55, alpha: 1)])
            button.bezelColor = bright ? NSColor(white: 0.94, alpha: 1) : nil
        }
        if let control = effects {
            for (i, effect) in Effect.allCases.enumerated() where control.isSelected(forSegment: i) != (s.effect == effect) {
                control.setSelected(s.effect == effect, forSegment: i)
            }
        }
        let style = "STYLE " + (s.style?.label ?? "AUTO")
        if style != shownStyle, let item = styleItem {
            shownStyle = style
            item.collapsedRepresentationLabel = style
            styleList?.selectedIndex = styles.firstIndex { $0 == s.style } ?? 0
        }
        roll?.lit = s.rolling
        beat?.beat = s.beatInBar
        var note = ""
        if s.transition == nil, let bars = s.countdownBars { note = "\(bars)" }
        beat?.note = note
    }
}
