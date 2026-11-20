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
  (click to copy), the History window, language, *Paste Automatically*, *Remove Filler Words*, sounds,
  launch at login, and the data folder.
- The model is close to verbatim, so "um" / "uh" come through. *Remove Filler Words* (on by default,
  English only) strips them and repairs the punctuation around the gap; the verbatim text stays in the
  record (`rawText`) and in the History window. `Tools/cleaner-test/run.sh` checks the rules.
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

## Recording calls — or anything your Mac plays

Press **⌃⇧R** to start, **⌃⇧R** again to stop. You get a plain **.m4a** in `~/Music/Speakin` (both
sides of a Zoom/Teams/Meet call: what the Mac plays plus your voice), and a **.txt** transcript beside it.
The overlay shows a pulsing red badge while it records; *Recordings…* in the menu lists them with
Play / Reveal / Transcribe / Move to Trash.

- **Their side** comes from a CoreAudio process tap: the audio apps send to the speakers or headphones,
  captured before it gets there, whichever device you listen on. *Record From* limits it to one app.
  macOS asks once for **Audio Recording** permission (Privacy & Security → Audio Recording).
- **Your side** — *Your Voice* in the menu. *Automatic* records the microphone your call app is using
  (Speakin asks CoreAudio which mic other apps are capturing from, re-checked every second), so with
  AirPods in it records the AirPods mic even when the Mac's default input is the built-in one. With no call
  running it uses the default input — except an idle Bluetooth headset, which the built-in mic stands in
  for (opening a headset mic switches it to low-quality call mode). Or pick a microphone by hand, or turn
  your voice off. While recording, the menu shows *Your voice: …* with the mic in use.
- **Nothing the hardware does ends a recording.** The two sides are captured separately and mixed on one
  timeline by capture time; when a device changes (headset in or out, Bluetooth switching modes, a
  device unplugged, sleep) only that side is rebuilt, within about a second. The file is fragmented AAC:
  if Speakin dies mid-call, everything up to the last few seconds is still a playable file, and quitting
  mid-recording closes it properly.
- **The hotkey always works.** Pressed while a recording is starting or saving, it is acted on as soon as
  that step is done. Transcription runs on the side and never blocks the next recording; dictation
  (⇧⌘D) always goes first, and a transcription it interrupts starts over afterwards.
- Recording other people may need their consent where you live.

## Names it learns by itself

Speech models turn made-up names into similar-sounding words ("Nocaps" → "knockups" / "no caps",
"Kuddo" → "Cuddo"). Speakin fixes that with a vocabulary it builds on its own — see *Vocabulary…* in
the menu:

- **Sources, scanned automatically** (once a day, or *Rescan Mac*): names of your project folders
  (any folder holding several repositories or Xcode projects), `.xcodeproj` names, installed apps,
  macOS learned spellings, your user name. Ordinary dictionary words are filtered out with the spell
  checker, so only coined names remain. Documents, Desktop and Downloads are never read.
- **Corrections you make once**: in History, *Edit & Learn*, fix the misheard name, *Save & Learn*.
  The exact mistake ("Latauf" → "Lattouf") is remembered and the name joins the vocabulary.
- **How fixes are applied**, in order: learned corrections; casing ("nocaps" → "Nocaps"); phonetic
  near-misses that are not real words ("Cuddo" → "Kuddo", "Fannius" → "Phaneus"); phrases spelled like a
  name ("no caps" → "Nocaps") unless every word is an everyday word ("to text", "live now" — those need
  a learned correction). Real words that merely sound like a name ("speaking" ~ "Speakin") are never
  rewritten unless you taught that correction. The model's verbatim output stays in `rawText`.
- Names are also handed to the speech engine as contextual strings (Apple's dictation engine honours
  them; the main long-form model currently ignores them).

Evaluated and rejected: a second engine pass (macOS allows one running analyzer per process, and the
dictation engine is less punctuated) and Apple's on-device language model for deciding "speaking" vs
"Speakin" (wrong in roughly a third of cases in three prompt styles). `Tools/vocab-test/run.sh` covers
the phonetics, the fixer rules, learning and persistence.

## Languages

*Language* in the menu lists every locale with an on-device model. Locales the long-form
`SpeechTranscriber` supports come first; the rest use `DictationTranscriber` (the keyboard dictation
engine). Default: the system language, falling back to English (US).

## Automation

`speakin://toggle`, `speakin://start`, `speakin://stop`, `speakin://history`, `speakin://vocabulary` — for Shortcuts, Raycast,
a Stream Deck, or `open speakin://toggle` from a script. Recording: `speakin://record` (toggle),
`speakin://record-start`, `speakin://record-stop`, `speakin://recordings`.

Launch-time overrides go through the standard defaults argument domain, e.g.
`open Speakin.app --args -autoPaste NO`.

## Debugging

```bash
log stream --level info --predicate 'subsystem == "com.bylivebetter.apps.Speakin"'
```

While recording, the log shows which devices are in use, every rebuild and microphone switch, and peak
levels of each side every 30 s. `open Speakin.app --args -SpeakinTestChurnSeconds 3` rebuilds both
captures every 3 s, as if the hardware kept changing; `say -a "<output device>" …` plays test speech to a
device you are not listening on, and the tap still records it.

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
  Audio/SessionRecorder.swift  call recording: supervises both captures, follows the call's mic, writes the file
  Audio/SessionCapture.swift   process tap (their side) and direct microphone IOProc (your side)
  Audio/SessionMixer.swift     one timeline, sources placed by capture time
  Audio/SessionWriter.swift    fragmented AAC .m4a writer
  Audio/AudioDevices.swift     device queries: clock device, microphones, which mic a call is using
  Audio/AudioProcessList.swift apps playing audio, for Record From
  SessionController.swift    record → save → transcribe, hotkey handling
  Sessions/SessionStore.swift  ~/Music/Speakin is the source of truth; metadata in Application Support
  Speech/SpeechEngine.swift  SpeechAnalyzer wrapper: assets, live sessions, file transcription
  Speech/TranscriptCleaner.swift  filler-word removal
  Vocabulary/                VocabularyStore (sources, learning), VocabularyFixer, Phonetics, WordOracle, TranscriptDiff
  Storage/TranscriptionStore.swift
  Input/HotkeyManager.swift  Carbon global hotkey (no Accessibility needed)
  Input/Paster.swift         pasteboard + synthetic ⌘V (Accessibility needed)
  UI/OverlayPanel.swift, UI/OverlayView.swift, UI/StatusMenuController.swift, UI/HistoryView.swift, UI/VocabularyView.swift,
  UI/SessionsView.swift
```

## Known limitations / next ideas

- The hotkey is fixed to ⇧⌘D (`Hotkey.default` in `HotkeyManager.swift`). While Speakin runs, it wins over
  apps that use the same shortcut (Mail's *Send*, for example).
- The clipboard is overwritten by each transcription (it is also in History).
- Real-word collisions ("speaking" for "Speakin") need one correction in History before they are fixed.
- The engine is behind a small wrapper (`SpeechEngine`), so a Whisper/Parakeet backend could be added
  without touching the rest.
