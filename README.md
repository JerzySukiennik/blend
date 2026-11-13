# Blend

A native macOS remix console played from the trackpad and keyboard. Two stem decks, a beat clock that keeps them locked, an automix that picks the moment, and eight moves you fire on the beat.

Built for one MacBook and one listener. The song library is private and is not part of this repository.

## What it does

- **Two decks, four stems each**: vocal, drums, bass, music. Every stem can be muted on its own.
- **Automix**: queue songs, Blend picks a phrase boundary and blends with a bass swap in the middle. Space forces the mix from the next four-bar boundary.
- **Different tempos**: within about 8% the tempo glides from one song to the other during the blend and the pitch stays put. Further apart, the mix becomes an echo cut. Songs played by a live drummer are straightened onto a steady grid when they load.
- **Moves** (always quantized to the bar):
  - `space` MIX: stem blend into the next song
  - `V` VOCAL: next song's vocal over the current beat, key matched
  - `B` BEAT: current vocal over the next song's drums and bass
  - `U` BUILD: four-bar filter and roll build, then the next song's drop
  - `D` DROP: jump to the next drop
  - `L` LOOP: four-beat loop, `[` and `]` halve and double it
  - `E` ECHO: echo out into the next song
  - `K` BRAKE: vinyl brake into the next song
- **Trackpad as the console** (Tab switches between cursor and console):
  - left half and right half are the two platters, one finger scratches like vinyl
  - two fingers up or down on a platter sweep a filter that springs back
  - the bottom strip is a crossfader that scrubs the same stem blend by hand
  - bottom corners play and pause each deck
- **Keys**: `1 2 3 4` mute Deck A stems, `7 8 9 0` Deck B stems, `S` re-syncs a scratched deck, `A` toggles automix, `/` replays the tour.

## Layout

- `Sources/BlendEngine`: C++ audio engine. Decks are slaved to a master beat clock, stems are time-stretched separately (Signalsmith Stretch), automation is scheduled in beats and fired sample-accurately. Also the analyzer (beat grid, downbeat and phrase phase, key, loudness) and the tempo straightener, which resamples a drifting song by a percent or two so its beats land on a constant grid.
- `Sources/BlendKit`: Swift. Library on disk, track loading, song structure, transition planning, the live session.
- `Sources/Blend`: the app. SwiftUI for the chrome, Core Animation layers for platters and waveforms, raw `NSTouch` for the trackpad.
- `Sources/blendtool`: offline tests. `selftest` checks beat sync and CPU cost, `grid` measures how tightly the drums sit on the beat grid, `automix` renders a scripted session without audio output.

## Build

```
./build.sh install
```

Needs Xcode 26 on macOS 26. The library lives in `~/Music/Blend/Library`, one folder per song with `vocals.m4a`, `drums.m4a`, `bass.m4a`, `other.m4a`, optional `beats.json` and `cover.jpg`. A folder with a single `mix.*` file plays without stems. Dropping audio files on the window adds them that way.

## Credits

- Time-stretch: [Signalsmith Stretch](https://github.com/Signalsmith-Audio/signalsmith-stretch) and Signalsmith Linear, MIT.
- Stem separation and beat tracking for the private library run offline with Demucs and Beat This.
