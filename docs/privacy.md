# Privacy

Alethia is designed to keep **all audio and transcripts on your Mac**.

## What stays local

- Microphone and system-audio buffers
- Whisper / VAD / speaker-embedding inference
- SQLite knowledge base (sessions, utterances, speakers, dictations)
- Speaker gallery embeddings and display names

No cloud account is required for v1. No analytics of conversation content.

## Indicators and control

- Ambient listening shows a visible menu-bar indicator.
- Ambient can be paused or stopped at any time.
- Dictation only runs while the hotkey session is active.
- Users can delete sessions, dictations, or the entire local database.

## Consent and legality

Recording conversations may require consent depending on jurisdiction, workplace policy, and context. Alethia shows an onboarding reminder but **does not** replace your legal obligations. When in doubt, ask before recording.

## Permissions (macOS)

| Permission | Why |
|------------|-----|
| Microphone | Ambient + dictation capture |
| Accessibility | Insert dictated text into other apps |
| Screen Recording / System Audio | Capture meeting audio without a bot (macOS 14.4+) |

## Data retention defaults

- Transcripts and metadata: kept until the user deletes them
- Raw audio clips: **not retained by default** (optional short TTL can be enabled later)
- Models: stored under `Models/` / Application Support; never uploaded by Alethia

## Security notes

- Database lives in the app sandbox / Application Support
- No network calls are required for core features; model download is an explicit user action via `Scripts/download-models.sh` or first-run UI
