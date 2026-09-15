# Speakin

Press **⇧⌘D**, speak, press **⇧⌘D** again — the text is pasted where your cursor is.
Runs entirely on your Mac with Apple's on-device speech model (macOS 26). Nothing leaves the machine.

It never loses a speech: audio is written to disk while you talk, transcription runs live while you
talk (so stopping finalizes in well under a second even after minutes), and anything that could not be
transcribed is retried on the next launch. The last **30 recordings** and **1000 transcriptions** are kept.

## Requirements

- macOS 26 (Tahoe) — uses the `SpeechAnalyzer` / `SpeechTranscriber` API.
- Xcode 26 to build.

## Build & run

Open `Speakin.xcodeproj` in Xcode and press ⌘R, or from the terminal:

```bash
xcodebuild -project Speakin.xcodeproj -scheme Speakin -configuration Debug -derivedDataPath build build && open build/Build/Products/Debug/Speakin.app
```

To install a Release build into `/Applications` (replaces a previous copy and relaunches):

```bash
Tools/install.sh
```

## First launch

1. **Microphone** — macOS asks on first launch.
2. **Accessibility** — needed to send ⌘V into the app you are dictating into. macOS asks on first launch;
   if you dismissed it, use *Allow Pasting (Accessibility)…* in the menu. Without it, the text is only
   copied to the clipboard (the overlay shows a clipboard icon instead of a check mark).
3. The speech model for your language is downloaded once by macOS if it is not already installed
   (the overlay shows a progress ring). English (US) was already present on this Mac.

## Using it

- The **round overlay** floats above everything, on every Space and over full-screen apps. Drag it anywhere;
  the position is remembered. It never steals keyboard focus.
- **⇧⌘D** (or a click on the overlay) starts recording; **⇧⌘D** again stops, transcribes and pastes.
- The overlay colours: dark = ready · red (pulsing with your voice) = recording · blue = transcribing ·
  green check = pasted · green clipboard = copied only · orange = heard nothing / error (hover for details).
- **Right-click the overlay** or click the **menu bar icon** for: start/stop, the last 8 transcriptions
  (click to copy), the History window, language, *Paste Automatically*, sounds, launch at login,
  and the data folder.
- **History window**: search, copy, re-transcribe (while the audio is still kept), reveal the audio in
  Finder, delete.

## How it never loses anything

- Recording writes 16 kHz mono WAV to disk buffer by buffer, and a record file is created the moment
  recording starts. If Speakin dies mid-speech, the WAV header is repaired and the recording is
  transcribed on the next launch.
- Transcription runs live while you speak; stopping only finalizes the tail. If the live session fails,
  the file on disk is transcribed instead. A failed transcription keeps its audio and can be retried from
  the History window or the menu (*Transcribe N Pending Recordings*).
- If the audio hardware reconfigures mid-speech (headset connects, another app grabs the device), the
  engine is restarted and recording continues into the same file.
- Data lives in `~/Library/Application Support/Speakin/`:
  - `recordings/<id>.wav` — the newest 30 are kept.
  - `transcriptions/<id>.json` — the newest 1000 are kept, written atomically.
  Limits are constants in `TranscriptionStore`.

## Languages

*Language* in the menu lists every locale with an on-device model. Locales the long-form
`SpeechTranscriber` supports come first; the rest use `DictationTranscriber` (the keyboard dictation
engine). Default: the system language, falling back to English (US).

## Automation

`speakin://toggle`, `speakin://start`, `speakin://stop`, `speakin://history` — for Shortcuts, Raycast,
a Stream Deck, or `open speakin://toggle` from a script.

Launch-time overrides go through the standard defaults argument domain, e.g.
`open Speakin.app --args -autoPaste NO`.

## Debugging

```bash
log stream --level info --predicate 'subsystem == "com.bylivebetter.apps.Speakin"'
```

`Tools/probe/run.sh` pushes a `say`-generated sentence through the exact microphone → converter → WAV →
live-transcription path, then through the crash-recovery (file) path, without touching the mic.
`Tools/make-icon.sh` regenerates the app icon.

## Layout

```
Speakin/
  main.swift                 entry point (nib-less AppKit)
  AppDelegate.swift          overlay + menu bar + history window + URL scheme
  AppController.swift        idle → recording → transcribing → pasted state machine, recovery
  Settings.swift             UserDefaults-backed preferences
  Audio/AudioRecorder.swift  AVAudioEngine capture → 16 kHz mono → WAVWriter + live feed
  Audio/WAVWriter.swift      crash-safe WAV writer with header repair
  Audio/AudioFormatConverter.swift
  Speech/SpeechEngine.swift  SpeechAnalyzer wrapper: assets, live sessions, file transcription
  Storage/TranscriptionStore.swift
  Input/HotkeyManager.swift  Carbon global hotkey (no Accessibility needed)
  Input/Paster.swift         pasteboard + synthetic ⌘V (Accessibility needed)
  UI/OverlayPanel.swift, UI/OverlayView.swift, UI/StatusMenuController.swift, UI/HistoryView.swift
```

## Known limitations / next ideas

- The hotkey is fixed to ⇧⌘D (`Hotkey.default` in `HotkeyManager.swift`). While Speakin runs, it wins over
  apps that use the same shortcut (Mail's *Send*, for example).
- The clipboard is overwritten by each transcription (it is also in History).
- Custom vocabulary (product names, people) can be fed to the model through
  `AnalysisContext.contextualStrings` — not wired up yet.
- The engine is behind a small wrapper (`SpeechEngine`), so a Whisper/Parakeet backend could be added
  without touching the rest.
