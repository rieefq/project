# Aside — Privacy, Security & Control

Trust is a product feature, not a setting. The defaults below apply without the user doing anything.

## The microphone

- The microphone is on **only during an interaction** — after the shortcut, a tap, a control, or Siri hands off — and during Aside's reply (so you can interrupt). It turns off when the interaction ends.
- The system microphone indicator is the source of truth; Aside never implies it is listening when it isn't, and doesn't claim a wake word it doesn't have.
- Audio is processed on device and never stored or uploaded by Aside. With SpeechAnalyzer, recognition is fully on device. During first-run fallback, SFSpeechRecognizer runs on device where the language supports it; otherwise Apple's recognizer may process audio on Apple's servers (disclosed in the permission prompt and Privacy settings).

## What leaves the device

| Request type | Leaves the device? | What is sent |
|---|---|---|
| Reminders, timers, calendar, music control, notes, memory, settings, time/math | No (understood locally) | — |
| Weather, places, travel time | To Apple's WeatherKit/MapKit | Location or place name |
| Music | To Apple Music or Spotify | The search query |
| Open questions / multi-step requests (cloud on) | To the configured Claude endpoint | The request text, current time, city-level location, preferences, and only the notes relevant to the request (sensitive notes only when they're exactly what was asked) |
| "On this device only" mode | Nothing to the cloud | — |

The cloud conversation lives only for the session and is discarded after five quiet minutes.

## Data at rest

| Data | Where | Protection | Retention |
|---|---|---|---|
| Memory (notes, facts, preferences, commitments) | App container | AES-GCM per file, 256-bit key in Keychain (this device only), iOS file protection, excluded from backups | Until the user deletes it |
| Activity journal (summaries of actions, no audio or raw transcripts) | App container | Same | 30 days by default (1–90) |
| Preferences, timers, proactivity budget | App container | Same | — |
| Claude key / relay token, Spotify tokens | Keychain | `AfterFirstUnlockThisDeviceOnly` | Until removed |

**Erase all Aside data** (Settings › Privacy, requires device authentication) deletes all of it, including the encryption key.

## Memory under the user's control

- Aside remembers what you **explicitly** ask it to ("remember…", "note that…").
- If it notices something worth keeping, it **asks first** ("Want me to remember that you prefer window seats?") — or never, if you choose "Only when I ask". A cloud model claiming the user asked is double-checked against the user's actual words.
- Text that looks sensitive (codes, passwords, health, finance) is flagged, kept out of cloud context unless it's exactly what's being asked about, and shown with a lock in settings.
- Review, delete individual items, export to JSON, or forget everything (device authentication). By voice: "what do you know about me?", "forget that", "forget everything".

## Actions and consent

Every action passes through one policy engine, whatever produced it:

| Tier | Examples | What happens |
|---|---|---|
| Read | Schedule, weather, recall | Runs immediately |
| Reversible | Create/move a reminder, timer, note, play music, personal events | Runs immediately; brief acknowledgement; undo available |
| Consequential | Send a message, call, change or delete events others are on, delete things, forget everything | Shown with who/what/consequence and approved by a **tap**, the platform's own compose/call sheet, or **Face ID / Touch ID / passcode** |
| Restricted | Purchases, payments, transfers, publishing, account changes | Not performed in V1 |

- **Voice is never authentication.** A spoken "yes" is accepted only for low-stakes clarifications (e.g. "remember that?"). For consequential actions Aside says "Tap Send to confirm."
- **No silent sending.** Messages open the system compose sheet pre-filled; the user sends. On the Mac, Aside says the message "is ready to send", because it can't observe the send.
- **Prompt-injection defense.** Web content is treated as information, never instruction. After external content enters a turn, even reversible writes need a quick confirmation, and consequential ones always do.
- **Honest reporting.** Tools return success only after the service confirms. Timeouts on writes are reported as "I'm not sure it went through" rather than as success or failure.
- **No duplicates.** Retries and repeated model calls are deduplicated by idempotency key.

## Proactivity limits

Aside may offer one follow-up immediately after an action (e.g. "Want a reminder for that?") and may send at most a few notifications a day (default 3), never during quiet hours (22:00–07:00 by default), never twice for the same thing, and stops a kind of suggestion entirely after it's been dismissed three times.

## Permissions

Requested just in time, the first time a request needs them, with plain usage strings. Settings › Connections shows every permission and links to the system page when one was declined. The macOS app is sandboxed with hardened runtime and only the entitlements it uses.

## Children, health, and dependence

Aside is not a health or wellness product and does not give medical, legal or financial advice beyond general information. It describes itself as an AI when asked, avoids emotional manipulation and engagement tactics, and is designed to be used less, not more.
