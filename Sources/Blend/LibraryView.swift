// Blend app: the library screen (search, blend filter, song list with fit indicator, voice list, queue column, file drop).
import BlendKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Bindable var model: AppModel
    @FocusState private var searching: Bool

    var body: some View {
        let session = model.session
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.dim)
                    TextField(model.showVoices ? "Search voices" : "Search your library", text: $model.search)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($searching)
                        .onChange(of: model.search) { _, _ in model.selected = 0 }
                    if let name = session.analyzing {
                        Text("Analyzing \(name)").font(.system(size: 12)).foregroundStyle(Theme.dim).lineLimit(1)
                    }
                    if !model.showVoices { FitsChip(model: model) }
                    VoicesChip(model: model)
                }
                .padding(.leading, 14)
                .padding(.trailing, 6)
                .frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panel))

                let list = model.filtered
                if model.showVoices {
                    VoiceList(model: model)
                } else if list.isEmpty {
                    VStack(spacing: 8) {
                        let fitting = model.onlyFits && session.mixReference != nil
                        Text(session.library.isEmpty ? "Your library is empty" : fitting ? "Nothing here blends smoothly with \(session.mixReference?.title ?? "it")" : "Nothing matches").font(.system(size: 17, weight: .semibold))
                        Text(fitting ? "Turn off the filter to see every song. Blend can still cut into any of them." : "Drop audio files anywhere in this window to add them.").font(.system(size: 13)).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(Array(list.enumerated()), id: \.element.id) { index, info in
                                    LibraryRow(model: model, info: info, selected: index == model.selected)
                                        .id(info.id)
                                        .onTapGesture {
                                            model.selected = index
                                            model.enqueueSelected()
                                        }
                                }
                            }
                        }
                        .scrollIndicators(.never)
                        .onChange(of: model.selected) { _, new in
                            if list.indices.contains(new) { proxy.scrollTo(list[new].id) }
                        }
                    }
                }
                Text(model.showVoices ? "Click a voice to drop it over the music. Blend starts it so that the last word lands on the next change.  T in the console picks one for you." : "Click a song or press return to queue it.  Tab opens the console.  The bars show how smoothly a song blends with the last one you picked.")
                    .font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            QueueColumn(model: model).frame(width: 320)
        }
        .padding(.horizontal, 26)
        .padding(.bottom, 22)
        .onAppear { searching = true }
        .onDrop(of: [.fileURL], isTargeted: $model.dropTargeted) { providers in
            Task {
                var urls: [URL] = []
                for p in providers {
                    if let url = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? URL {
                        urls.append(url)
                    } else if let data = try? await p.loadItem(forTypeIdentifier: UTType.fileURL.identifier) as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        urls.append(url)
                    }
                }
                await model.session.importFiles(urls)
            }
            return true
        }
        .overlay {
            if model.dropTargeted {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.text.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.black.opacity(0.45)))
                    .overlay(Text("Drop to add to your library").font(.system(size: 20, weight: .semibold)))
                    .padding(14)
            }
        }
    }
}

struct FitsChip: View {
    let model: AppModel
    @State private var hover = false

    var body: some View {
        let ref = model.session.mixReference
        let on = model.onlyFits && ref != nil
        HStack(spacing: 7) {
            FitBars(level: 3, tint: on ? Theme.ink : (ref == nil ? Theme.faint : Theme.dim))
            Text(ref.map { on ? "Blends with \($0.title)" : "Only what blends with \($0.title)" } ?? "Only what blends").lineLimit(1)
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(on ? Theme.ink : (ref == nil ? Theme.faint : Theme.dim))
        .padding(.horizontal, 11)
        .frame(height: 28)
        .frame(maxWidth: 300)
        .fixedSize(horizontal: true, vertical: false)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.text : (hover && ref != nil ? Theme.panelStrong : Theme.panel)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { if ref != nil { withAnimation(Theme.snappy) { model.toggleFits() } } }
        .help(ref == nil ? "Play or queue a song first, then show only the songs that blend smoothly with it" : "Show only songs whose tempo and key blend smoothly with the last song you picked")
        .animation(Theme.snappy, value: on)
    }
}

struct VoicesChip: View {
    let model: AppModel
    @State private var hover = false

    var body: some View {
        let on = model.showVoices
        HStack(spacing: 7) {
            Image(systemName: "quote.bubble.fill").font(.system(size: 11, weight: .semibold))
            Text("Voices")
        }
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(on ? Theme.ink : Theme.dim)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .fixedSize()
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(on ? Theme.text : (hover ? Theme.panelStrong : Theme.panel)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { withAnimation(Theme.snappy) { model.toggleVoices() } }
        .help("Famous lines you can drop over the mix")
        .animation(Theme.snappy, value: on)
    }
}

struct VoiceList: View {
    let model: AppModel

    var body: some View {
        let list = model.voices
        if list.isEmpty {
            VStack(spacing: 8) {
                Text(model.session.speeches.isEmpty ? "No voices yet" : "Nothing matches").font(.system(size: 17, weight: .semibold))
                Text("Voice clips live in Music/Blend/Speeches.").font(.system(size: 13)).foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(list.enumerated()), id: \.element.id) { index, speech in
                            VoiceRow(model: model, speech: speech, selected: index == model.selected)
                                .id(speech.id)
                                .onTapGesture {
                                    model.selected = index
                                    model.speakSelected()
                                }
                        }
                    }
                }
                .scrollIndicators(.never)
                .onChange(of: model.selected) { _, new in
                    if list.indices.contains(new) { proxy.scrollTo(list[new].id) }
                }
            }
        }
    }
}

struct VoiceRow: View {
    let model: AppModel
    let speech: Speech
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let speaking = model.session.speaking?.id == speech.id
        HStack(spacing: 12) {
            Text(speech.year > 0 ? String(speech.year) : "").font(.system(size: 12.5, weight: .bold)).monospacedDigit()
                .foregroundStyle(speaking ? Theme.ink : Theme.dim)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(speaking ? Theme.text : Theme.panelStrong))
            VStack(alignment: .leading, spacing: 2) {
                Text(speech.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(speech.speaker).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(timeText(speech.seconds.rounded())).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 38, alignment: .trailing)
            Image(systemName: speaking ? "stop.fill" : "play.fill").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(speaking || hover || selected ? Theme.text : Theme.faint)
                .frame(width: 28)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.panelStrong : (hover ? Theme.panel : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(Theme.snappy, value: speaking)
    }
}

struct FitBars: View {
    let level: Int
    var tint = Theme.text

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1).fill(i < level ? tint : Theme.faint.opacity(0.5)).frame(width: 3, height: CGFloat(5 + i * 4))
            }
        }
        .frame(height: 13, alignment: .bottom)
    }
}

struct LibraryRow: View {
    let model: AppModel
    let info: TrackInfo
    let selected: Bool
    @State private var hover = false

    var body: some View {
        let session = model.session
        let a = session.analyses[info.id]
        let position = session.queue.firstIndex(of: info)
        let onDeck = session.decks.contains { $0.track?.info.id == info.id } && position == nil
        HStack(spacing: 12) {
            Cover(info: info, size: 44, radius: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.title).font(.system(size: 14.5, weight: .semibold)).lineLimit(1)
                Text(info.artist.isEmpty ? "Unknown artist" : info.artist).font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 8)
            if !info.hasStems {
                Text("NO STEMS").font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(Theme.dim)
                    .padding(.horizontal, 7).padding(.vertical, 3).background(Capsule().strokeBorder(Theme.line))
            }
            if let a {
                Text(bpmText(a.bpm)).font(.system(size: 13.5, weight: .semibold)).monospacedDigit().frame(width: 46, alignment: .trailing)
                Text(a.keyName).font(.system(size: 13)).foregroundStyle(Theme.dim).frame(width: 36, alignment: .leading)
                Text(timeText(a.seconds)).font(.system(size: 12.5)).monospacedDigit().foregroundStyle(Theme.dim).frame(width: 38, alignment: .trailing)
                FitBars(level: session.fit(info)).frame(width: 16).opacity(session.mixReference == nil || session.mixReference?.id == info.id ? 0 : 1)
            } else {
                Text("…").foregroundStyle(Theme.dim).frame(width: 150, alignment: .trailing)
            }
            ZStack {
                if onDeck {
                    Image(systemName: "waveform").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
                } else if let position {
                    Text("\(position + 1)").font(.system(size: 12.5, weight: .bold)).foregroundStyle(Theme.ink).frame(width: 24, height: 24).background(Circle().fill(Theme.text))
                } else {
                    Image(systemName: "plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(hover || selected ? Theme.text : Theme.faint)
                }
            }
            .frame(width: 28)
        }
        .padding(.horizontal, 10)
        .frame(height: 58)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Theme.panelStrong : (hover ? Theme.panel : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Remove from Library") { session.removeFromLibrary(info) }
        }
    }
}

func timeText(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return String(format: "%d:%02d", s / 60, s % 60)
}

struct QueueColumn: View {
    let model: AppModel

    var body: some View {
        let session = model.session
        VStack(alignment: .leading, spacing: 12) {
            if let c = session.current, let t = session.decks[c].track {
                VStack(alignment: .leading, spacing: 8) {
                    Text(session.paused ? "PAUSED" : "NOW PLAYING").font(.system(size: 10.5, weight: .bold)).tracking(1).foregroundStyle(Theme.dim)
                    HStack(spacing: 12) {
                        Cover(info: t.info, size: 52, radius: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.info.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                            Text("\(t.info.artist)  \(bpmText(t.analysis.bpm)) BPM  \(t.analysis.keyName)").font(.system(size: 12.5)).foregroundStyle(Theme.dim).lineLimit(1)
                            if let bars = session.countdownBars, session.transition == nil {
                                Text("Mixing in \(bars) \(bars == 1 ? "bar" : "bars")").font(.system(size: 12, weight: .semibold)).contentTransition(.numericText())
                            } else if session.transition != nil {
                                Text("Mixing now").font(.system(size: 12, weight: .semibold))
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel))
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Up Next").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Text(session.queue.isEmpty ? "" : "\(session.queue.count) \(session.queue.count == 1 ? "song" : "songs")").font(.system(size: 12)).foregroundStyle(Theme.dim)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
                if session.queue.isEmpty {
                    Text("Queue songs from the list.\nThe first one loads onto the free deck.").font(.system(size: 12.5)).foregroundStyle(Theme.dim).padding(.horizontal, 6).lineSpacing(3)
                }
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(Array(session.queue.enumerated()), id: \.element.id) { index, info in
                            QueueRow(model: model, info: info, index: index)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.panel.opacity(0.6)))
        }
        .animation(Theme.spring, value: session.queue)
    }
}

struct QueueRow: View {
    let model: AppModel
    let info: TrackInfo
    let index: Int
    @State private var hover = false

    var body: some View {
        let session = model.session
        HStack(spacing: 10) {
            Cover(info: info, size: 38, radius: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(detail(session)).font(.system(size: 11.5)).foregroundStyle(Theme.dim).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hover {
                HStack(spacing: 2) {
                    iconButton("chevron.up") { session.moveInQueue(from: index, to: index - 1) }
                    iconButton("chevron.down") { session.moveInQueue(from: index, to: index + 1) }
                    iconButton("xmark") { session.dequeue(info) }
                }
            } else {
                FitBars(level: session.fit(info, to: previous(session))).opacity(previous(session) == nil ? 0 : 1)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? Theme.panel : Color.clear))
        .onHover { hover = $0 }
    }

    private func previous(_ session: Session) -> TrackInfo? {
        index > 0 && index <= session.queue.count ? session.queue[index - 1] : session.current.flatMap { session.decks[$0].track?.info }
    }

    private func detail(_ session: Session) -> String {
        var parts = [info.artist]
        if let a = session.analyses[info.id] { parts.append(bpmText(a.bpm)) }
        if index == 0, session.decks.contains(where: { $0.loading?.id == info.id }) { parts.append("loading") }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func iconButton(_ name: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 10.5, weight: .bold)).foregroundStyle(Theme.dim).frame(width: 24, height: 24).background(Circle().fill(Theme.panel))
        }
        .buttonStyle(.plain)
    }
}
