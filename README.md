# Blend

A native macOS remix console played from the trackpad and keyboard. Two stem decks, a beat clock that keeps them locked, an automix that picks the moment and the technique, and moves you fire on the beat.

Built for one MacBook and one listener. The song library is private and is not part of this repository.

## What it does

- **Two decks, four stems each**: vocal, drums, bass, music. Every stem can be muted on its own.
- **Automix**: queue songs, Blend picks a phrase boundary and mixes like a DJ would, rotating through ten techniques so two transitions in a row never sound the same. Whatever the technique, only one drum kit, one bass and one lead vocal sound at a time. Space forces the mix from the next four-bar boundary, `M` picks the technique yourself.
  - `SWAP`: the next song comes in thin, drums first, then its music; on the phrase the lows trade places; the old song leaves through a rising filter and an echo tail.
  - `MELT`: the old song sinks under a low-pass while the new one opens up on top of it.
  - `CARRY`: the old vocal keeps singing over the new song's beat, then echoes out.
  - `RIDE`: only the new drums ride underneath, the old song gets filter and echo, clean swap on the phrase.
  - `LOOP`: the old song locks into a loop that halves again and again while the new drums build, the new song lands on the one.
  - `CHOP`: the two songs trade beats for two bars like a crossfader cut, then the new one takes over.
  - `BRIDGE`: the old song is stripped to its drums, the drums loop and glide to the new tempo, the new song comes in on top. This is how songs with very different tempos are joined without a cut.
  - `ROLL`: stutter build on the old song, the new one drops in.
  - `WASH`: the old song washes out in filter and echo over a few bars.
  - `SPIN`: spinback into the new song.
- **The moment**: the old song hands over where its vocal pauses, not in the middle of a line, and before a fade-out gets quiet. The next song is placed so that its first full bar or its first sung line starts exactly at the handover: a long intro is trimmed, a song that starts singing right away comes in later. It is also nudged by a few milliseconds onto the kicks of the song that is playing.
- **Keys**: when both keys are heard clearly and sit at most a semitone apart from a match, the next song is nudged by that semitone and the two play together (`SWAP`, `MELT`, `CARRY`). Only closely related keys count as a match. Otherwise Blend uses `RIDE`, `LOOP` or `CHOP`, where nothing melodic overlaps.
- **Different tempos**: within about 10% the tempo glides from one song to the other during the blend and the pitch stays put. Between 11% and 22% the two songs meet halfway, and the tempo settles on the new song over the next eight bars. Further apart, Blend uses `BRIDGE` two times out of three and a cut (`WASH`, `ROLL` or `SPIN`) the third time.
- **Wandering tempos**: songs played by a live drummer, and even an orchestra, are straightened onto a steady grid when they load. Small drifts are resampled as they are; large ones (a few percent and more) also get their pitch corrected during playback, so nothing sounds like a warped tape.
- **Two versions of one song**: a cover or remix can be linked to the original. Whenever the two are mixed or mashed up, the incoming one starts at the same moment of the song.
- **Moves** (always quantized to the beat grid):
  - `space` MIX: blend into the next song
  - `M` STYLE: cycle the technique for the next mix, AUTO lets Blend choose
  - `V` VOCAL: next song's vocal over the current beat, key matched
  - `B` BEAT: current vocal over the next song's drums and bass (an instrumental keeps its melody instead)
  - `U` BUILD: four-bar filter and roll build, then the next song's drop
  - `D` DROP: jump to the next drop
  - `L` LOOP: four-beat loop, `[` and `]` halve and double it
  - `R` ROLL: hold to stutter the beat, `[` tightens it, release and the song is back where it would have been
  - `E` ECHO: echo out into the next song
  - `K` BRAKE: vinyl brake into the next song
  - `X` SPIN: spinback into the next song
- **Trackpad as the console** (Tab switches between cursor and console):
  - left half and right half are the two platters, one finger scratches like vinyl, a finger held still stops the record
  - two fingers up or down sweep a filter that springs back
  - a slide along the bottom edge is a crossfader that scrubs the blend by hand, at any tempo difference
  - a tap in a bottom corner plays or pauses that deck
  - the direction of the movement decides, not only where the finger landed: a sweep that starts on the bottom strip is still a filter, a slide that starts in a corner is still the crossfader
- **Library**: every song shows how smoothly it would blend with the last song you picked. One click on "Only what blends" hides everything that would need a cut.
- **Other keys**: `1 2 3 4` mute Deck A stems, `7 8 9 0` Deck B stems, `S` re-syncs a scratched deck, `A` toggles automix, `/` replays the tour.

## Layout

- `Sources/BlendEngine`: C++ audio engine. Decks are slaved to a master beat clock, stems are time-stretched separately (Signalsmith Stretch), automation is scheduled in beats and fired sample-accurately. Also the analyzer (beat grid, downbeat and phrase phase, key, loudness) and the tempo straightener, which resamples a drifting song so its beats land on a constant grid and, when the speed change is large, keeps a pitch correction curve that the decks apply through the stretcher.
- `Sources/BlendKit`: Swift. Library on disk, track loading, song structure, transition techniques and planning, the live session, and the trackpad gesture rules (`TouchBoard`, free of AppKit).
- `Sources/Blend`: the app. SwiftUI for the chrome, Core Animation layers for platters and waveforms, raw `NSTouch` for the trackpad.
- `Sources/blendtool`: offline tests. `selftest` checks beat sync and CPU cost, `touch` replays finger sequences through the gesture rules, `grid` measures how tightly the drums sit on the beat grid, `pairs` counts how the library's song pairs would be mixed, `automix` renders a scripted session without audio output (`--trace` prints every lane during a transition).

## Build

```
./build.sh install
```

Needs Xcode 26 on macOS 26. The library lives in `~/Music/Blend/Library`, one folder per song with `vocals.m4a`, `drums.m4a`, `bass.m4a`, `other.m4a`, optional `beats.json` and `cover.jpg`. A folder with a single `mix.*` file plays without stems. Dropping audio files on the window adds them that way.

`meta.json` in a song folder may carry three hints:

- `"downbeat": <seconds>`, the time of any first beat of a bar, for music where the analyzer cannot tell where the bar starts (no drums).
- `"tempo": <bpm>`, a rough tempo, for songs the analyzer reads at double or half speed.
- `"twin": {"of": "<folder of the other version>", "semitones": <how much higher this version is>, "map": [[bar here, bar there], ...], "back": [[bar there, bar here], ...]}`, section starts of this version paired with the same sections of the other one. `back` is optional and is used when the other version is the one playing; `blendtool twin` prints the comparison the map is built from.

## Credits

- Time-stretch: [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) and Signalsmith Linear, MIT.
- Stem separation and beat tracking for the private library run offline with Demucs and Beat This.
