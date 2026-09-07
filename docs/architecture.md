# Architecture

Alethia is a Swift package with one executable target (`AlethiaApp`) and seven library
modules. The platform-independent modules (`Core`, `Text`, `Knowledge`, and the DSP parts of
`Audio`) build and test on Linux, which keeps CI fast; everything that touches AVFoundation,
CoreML, Accessibility or SwiftUI is macOS-only and behind `#if os(macOS)`.

```
                 ┌──────────────┐   hold key    ┌────────────────┐
 Microphone ───▶ │ Dictation    │ ────────────▶ │ SpeechEngine   │
                 │ Controller   │ ◀──── text ── │ (FluidAudio)   │
                 └──────┬───────┘               └───────┬────────┘
                        │ format                        │ ASR · VAD · diarization
                        ▼                               │
                 ┌──────────────┐                       │
                 │ Dictation    │                       │
                 │ Formatter    │                       │
                 └──────┬───────┘                       │
                        │ insert (AX / ⌘V / keys)       │
                        ▼                               ▼
                  Focused app                   ┌────────────────┐
                                                │ Meeting        │
 Mic + system audio ─▶ MeetingAudioCapture ───▶ │ Recorder →     │
                       (mixer, WAV, live feed)  │ Processor      │
                                                └───────┬────────┘
                                                        │ utterances, speakers, notes
                                                        ▼
                                                ┌────────────────┐
                                                │ KnowledgeStore │ SQLite + FTS5
                                                └────────────────┘
```

## Modules

### AlethiaCore
Plain value types shared by everything: `Meeting`, `Utterance`, `TimedWord`, `Speaker`,
`Dictation`, `DictionaryEntry`, `Snippet`, `NotesTemplate`, `SearchHit`; `AppSettings` with a
tolerant JSON `SettingsStore`; `AppPaths`; `PermissionGate` (TCC checks and System Settings
deep links); `KeychainStore`; a small PCM16 `WAVCodec`; and `TranscriptAligner`, which turns
word timings plus speaker segments plus mic/system loudness into speaker-attributed
utterances and decides which cluster is "You".

### AlethiaText
Everything that happens to words after recognition, all pure functions with tests:

- `DictationFormatter` — a staged pipeline: dictionary replacements → filler removal →
  self-correction resolution ("Tuesday, no, Wednesday") → voice commands ("new line",
  "period", "scratch that", "all caps …") → smart formatting (numbers, currency, dates,
  times, emails, URLs, phone numbers) → snippet expansion → app-aware style (`AppStyle`
  inferred from the target bundle id) → capitalization and spacing that joins with the
  text already before the cursor.
- `CorrectionLearner` — diffs inserted vs. edited text and proposes dictionary entries.
- `NotesGenerator` — heuristic notes (decisions, action items, questions, topics) and,
  when a `LanguageModelProvider` is configured, prompt-driven notes per template with
  guardrails; also suggests a title and one-line summary.
- `DictationPolisher` — optional LLM pass over formatted dictation that must preserve the
  user's words (rejected if it drifts too far).
- `OpenAICompatibleProvider` — `/v1/chat/completions` client for Ollama, LM Studio,
  llama.cpp server, OpenAI, etc. `AppleIntelligenceProvider` (in the app target) uses the
  Foundation Models framework on macOS 26.
- `MarkdownExport`.

### AlethiaKnowledge
`KnowledgeStore` wraps a single SQLite connection (WAL, foreign keys, `PRAGMA user_version`
migrations). Tables: meetings, utterances (with word timings as a Float32 blob), speakers
(256-d voiceprints), dictations, dictionary, snippets, templates, and an FTS5 index over
meeting titles/notes, utterances and dictations. A `sqlite3_update_hook` coalesces row
changes into one `didChangeNotification` per run-loop turn so the UI can refetch without
every mutator knowing about observers.

### AlethiaAudio
`MicrophoneCapture` (AVAudioEngine → 16 kHz mono Float32), `SystemAudioCapture`
(ScreenCaptureKit audio-only stream), `AudioMixer` (aligns the two sources in 100 ms hops,
records per-hop RMS of each source, soft-clips the sum), `WAVFileWriter` (streaming PCM16
with header repair for crash recovery), `MicrophoneActivityMonitor` (CoreAudio
`kAudioDevicePropertyDeviceIsRunningSomewhere`, used for meeting detection).

### AlethiaSpeech
`SpeechEngine` is an actor over FluidAudio:

- **ASR**: Parakeet TDT 0.6B (`AsrManager`). Two managers share one loaded model set so a
  meeting being finalized never blocks a dictation. Word timings come from
  `buildWordTimings`. Whole recordings go through `transcribeDiskBacked`.
- **Live partials**: `IncrementalTranscriber` re-decodes the uncommitted audio every
  ~450 ms with the same batch model (the model is ~200× real time on the ANE, so a 10 s
  window decodes in ~50 ms). Segments are committed at pauses so text before a pause
  stops changing; on release the whole clip is decoded once more for the final result.
  This gives punctuated, cased partials without a second streaming model.
- **VAD**: Silero via `VadManager`, with an energy-based fallback.
- **Diarization**: pyannote segmentation + WeSpeaker embeddings via `DiarizerManager`,
  run off the actor on a detached task.
- `ModelManager` tracks install state per component, downloads with progress through
  FluidAudio's `ProgressHandler`, and reports disk usage. Models live in FluidAudio's
  shared cache so the app bundle stays under 10 MB.

### AlethiaDictation
`HotkeyMonitor` (CGEventTap; modifier and function keys; hold vs. toggle; cancels if
another key is pressed during a hold), `TextInserter` (Accessibility `AXSelectedText`
with verification → ⌘V with pasteboard snapshot/restore → synthesized keystrokes; can
replace the last insertion for corrections), `DictationOverlayController` (non-activating
panel with level meter and partial text), `CorrectionPanelController` (editable popover
with a countdown), and `DictationController`, which sequences a session:

1. hotkey down → check target isn't a secure field → start mic + live transcriber → overlay
2. hotkey up → final decode → `DictationFormatter` (with the user's dictionary, snippets,
   app style, and preceding text) → optional LLM polish → insert
3. save to history, bump dictionary/snippet use counts, show correction popover
4. on edit → replace inserted text, store the edit, learn dictionary candidates

### AlethiaMeetings
`MeetingRecorder` (start/stop/discard, live transcript, editable title and notes while
recording, calendar context), `MeetingProcessor` (queue: transcribe file → diarize → align
→ match voiceprints against known speakers and update the "You" profile → save → notes →
optional title; recovers meetings interrupted by a crash), `MeetingDetector` (mic-in-use
plus a running conferencing app, with confirm and end grace periods), `CalendarService`
(EventKit).

### AlethiaApp
`AppEnvironment` is the composition root. `MenuBarExtra` popover for controls and recent
meetings; `OnboardingView` (permissions → models → hotkey); the Hub window with Meetings
(list, live view, notes editor, transcript with speaker renaming), Dictation history,
Dictionary & snippets, Speakers, and Settings. User notifications offer to record when a
call is detected.

## Concurrency model
Controllers and view models are `@MainActor`. Audio callbacks arrive on audio threads and
only push samples into thread-safe buffers or hop to the main actor for UI state.
`SpeechEngine` is an actor; heavy synchronous work (diarization) runs on detached tasks.
`KnowledgeStore` serializes SQLite access with a lock and is safe to call from any thread.

## Size budget
`Scripts/package-app.sh` fails if `Alethia.app` exceeds 10 MiB. FluidAudio has no binary
frameworks and models are downloaded at runtime, so the bundle is the Swift executable,
Info.plist, entitlements and icon.
