# Privacy

Alethia is designed to keep conversation audio and transcripts on your Mac.

## Principles

- No cloud ASR or analytics by default.
- No meeting bot joins calls; system audio uses ScreenCaptureKit when enabled.
- Meeting recording shows a visible menu-bar indicator.
- Meeting capture runs only while you have started recording.
- Dictation only runs while the Fn session is active.
- You are responsible for obtaining consent when recording others.

## Permissions

| Permission | Why |
|------------|-----|
| Microphone | Meeting + dictation capture |
| Accessibility | Global Fn monitoring + auto-paste into other apps |
| Screen Recording | Optional system audio for meetings |

## Data at rest

SQLite knowledge store under Application Support. Model weights for CrisperWhisper live in the Hugging Face cache used by the local sidecar; optional ECAPA weights under `Models/`.

See also [architecture.md](architecture.md).
