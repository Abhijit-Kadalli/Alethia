# Privacy

Alethia is designed so that you can dictate and record meetings without any of it leaving
your Mac.

## What runs where

| Step | Where | Notes |
|------|-------|-------|
| Speech recognition, voice activity, speaker separation | On device (Neural Engine / CPU) | Open-source CoreML models downloaded once from Hugging Face |
| Dictation cleanup (fillers, commands, formatting, dictionary) | On device | Rule-based |
| Meeting notes | On device | Heuristic notes by default. If you enable a language model, the transcript is sent to that model: Apple Intelligence stays on device; an OpenAI-compatible server is wherever you point it (a local Ollama is local; a cloud API is not) |
| Dictation polish (optional) | Same as notes | Off by default |
| Calendar titles and attendees | On device | Read-only EventKit access, only when enabled |

The only network requests Alethia makes on its own are the model downloads
(`huggingface.co`). There is no telemetry, crash reporting, or account.

## What is stored

Under `~/Library/Application Support/Alethia/`:

- `alethia.sqlite` — meetings, transcripts with word timings, your notes and generated notes,
  speaker profiles (256-number voiceprints, not audio), dictation history (raw recognizer
  output, final text, your edits, the target app), dictionary and snippets.
- `Recordings/<meeting-id>.wav` — 16 kHz mono audio of each meeting, kept so you can re-run
  transcription. Turn off *Keep audio recordings* in Settings › Meetings to delete them
  after processing, or delete all recordings under Settings › Privacy & data.

Dictation audio is never written to disk. Language-model API keys are kept in the macOS
Keychain. Models live in `~/Library/Application Support/FluidAudio/Models/` and can be
deleted from Settings › Models.

Everything can be deleted from Settings › Privacy & data or by removing the folder above.

## Permissions

- **Microphone** — to hear you.
- **Accessibility** — for the global dictation hotkey (a `CGEventTap` that only looks at the
  configured key) and to place text at the cursor. Alethia reads the focused text field's
  role and, for joining sentences, the text right before the cursor. Secure (password)
  fields are never touched.
- **Screen & System Audio Recording** — optional, to capture the other participants of a
  call. Alethia opens an audio-only ScreenCaptureKit stream; no video frames are captured.
- **Calendar** — optional, read-only.
- **Notifications** — to offer recording when a call is detected.

## Recording others

A red indicator is shown in the menu bar while recording, and the Hub shows the live
transcript. Recording laws vary by jurisdiction; you are responsible for telling
participants and obtaining consent where required.
