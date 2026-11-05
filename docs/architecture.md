# Aside — Architecture

## Shape of the system

```
 ┌──────────────── Apps (SwiftUI + AppKit/UIKit, thin) ────────────────┐
 │ macOS: menu bar · presence panel · ⌥Space hot key · settings        │
 │ iOS:   presence screen · App Intents (Siri/Action/Shortcuts) ·      │
 │        Control Center control · settings sheet                      │
 │ Shared adapters: audio engine (voice processing) · SpeechAnalyzer · │
 │   AVSpeechSynthesizer · Foundation Models · EventKit · MusicKit ·   │
 │   Spotify · WeatherKit · MapKit · Contacts · Messages · Keychain ·  │
 │   AES-GCM file store · LocalAuthentication                          │
 └──────────────────────────────┬──────────────────────────────────────┘
                                │ protocols (SpeechInput, SpeechOutput,
                                │ RemindersService, CalendarService, …)
 ┌──────────────────────── AsideKit (pure Swift) ──────────────────────┐
 │ Runtime      AgentRuntime: turn-taking, interruption, routing,      │
 │              confirmation/choice/slot dialogs, presentation         │
 │ Understanding  Tokenizer · FastPath grammar · TemporalParser ·      │
 │              DurationParser · ControlCommands · Corrections ·       │
 │              Endpointer · EchoGuard · AnswerParser · QuickAnswers   │
 │ Actions      ToolRegistry · ActionEngine · PolicyEngine ·           │
 │              ActionJournal · tools (reminders, calendar, timers,    │
 │              music, weather, places, messages, memory, settings)    │
 │ Reasoning    Reasoner protocol · ClaudeReasoner (SSE, tools, web    │
 │              search) · LocalIntentModel protocol · PersonaPrompt    │
 │ Memory       MemoryStore (keyword/BM25 recall, consent, export)     │
 │ Proactivity  ProactivityLedger (budget, quiet hours, back-off)      │
 └─────────────────────────────────────────────────────────────────────┘
```

**AsideKit** depends only on Foundation and Observation. It contains every decision — what was said, what it means, whether it's allowed, what to say back — and is covered by unit and end-to-end conversation tests that run headless. The apps implement small protocols with Apple frameworks. That split is the main reliability lever: the parts most likely to be wrong are the parts that are tested.

## A request, end to end

```
activation ─► mic + recognizer ─► transcript ─► endpointer ─► utterance
                                                                │
      ┌────────────────── routing (cheapest reliable first) ────┴──────┐
      │ 1 pending question?   → answer it (yes/no, choice, slot)        │
      │ 2 control command?    → stop / cancel / undo / repeat …         │
      │ 3 correction?         → patch the thing just done               │
      │ 4 fast-path grammar   → tool call               (~1 ms, offline)│
      │ 5 cloud model         → Claude + tools + web    (when allowed)  │
      │ 6 on-device model     → structured intent frame (offline, private)
      └──────────────────────────────┬─────────────────────────────────┘
                                     ▼
          ActionEngine: prepare → policy → (confirm/choose/ask/permit)
                        → dedupe → execute (timeout) → journal
                                     ▼
          presentation: earcon · speech plan · card · referent for "it"
```

- **Fast path first.** A deterministic grammar covers the requests people make most (reminders, timers, schedule, music, weather, time, math, messages, places, notes, settings). It never guesses; anything uncertain falls through. Personal questions ("what's my gate code?") try memory first and fall through when nothing is found.
- **Models do language, code does dates.** Every tool takes the user's own words for time (`when: "in 30 days"`), which `TemporalParser` grounds against the user's calendar, time zone and preferences. A model-computed ISO date is used only when the words can't be parsed. This removes a whole class of off-by-one-day failures.
- **One gate for every action.** Whether a call came from the grammar, the on-device model or Claude, it passes through `ActionEngine` and `PolicyEngine`. Models cannot skip confirmation.
- **Two-phase tools.** `prepare` validates and resolves (finds the contact, the reminder, the exact time) so a confirmation shows precise details; `execute` acts and must only report success the service confirmed.
- **Idempotency.** Identical writes in the same turn — or creations repeated within 90 s — are not executed twice ("That's already done.").
- **Undo by construction.** Every reversible result carries an `UndoPlan`; the journal powers "undo that", "cancel that" and the Activity view.

## Turn-taking and audio

- One `AVAudioEngine` per interaction with **voice processing** (echo cancellation, noise suppression). Speech output is synthesized to buffers and played through the same engine, so the canceller hears exactly what Aside says — that's what makes barge-in work on a speaker.
- `InputMonitor` runs an energy VAD with an adaptive noise floor and hysteresis on the audio thread and reports level/activity at ~30 Hz.
- Recognition uses **SpeechAnalyzer / SpeechTranscriber** (on-device, volatile + final results with audio time ranges for clean turn boundaries). Until its model is installed (downloaded in the background at first launch), **SFSpeechRecognizer** is used, on-device where supported.
- The engine starts on activation and stops 2.5 s after the interaction ends. Route changes (AirPods, Bluetooth, car) and interruptions (calls, Siri) are handled; the runtime stops cleanly and the user's audio is restored.

## Reasoning

- **ClaudeReasoner** talks to the Messages API directly with streaming SSE (`anthropic-version: 2026-10-21`). It defaults to `claude-opus-5-5` at `effort: low` (voice replies are short), with server-side refusal fallbacks (`fallbacks: "default"`), the web search tool for current information, eager tool-input streaming, and a cache breakpoint after the stable system prompt.
- Text streams into a **sentence chunker** so speech starts after the first clause, not the full reply. Markdown, URLs and symbols are stripped before speaking.
- The conversation is **append-only** for the session (thinking blocks and tool results echoed back verbatim) and discarded after five quiet minutes.
- Tool inputs are validated against their JSON Schemas before running; malformed or truncated inputs are returned to the model as errors, never executed. `max_tokens`, `pause_turn` and `refusal` stop reasons are handled explicitly.
- When a write tool succeeds, the app speaks its confirmation immediately and tells the model (`acknowledged_to_user`), which avoids a second round trip before the user hears "done".
- **LocalIntentModel** (Apple Foundation Models, guided generation) maps utterances to an `IntentFrame` — action plus the user's own words — when the cloud isn't available or allowed. Nothing leaves the device.
- Credentials: a Claude API key or an organization relay (bearer token) kept in the Keychain. Pointing `baseURL` at a relay is the intended production path for a consumer launch.

## Extensibility

Everything that might change is behind a protocol:

| Seam | V1 implementation | Later |
|---|---|---|
| `SpeechInput` | SpeechAnalyzer + SFSpeechRecognizer fallback | Wake-word detector front end; custom vocabulary via DictationTranscriber |
| `SpeechOutput` | AVSpeechSynthesizer (incl. Personal Voice) | Neural/cloud voices with the same buffer pipeline |
| `Reasoner` | ClaudeReasoner | Other models, a relay with org policies, model routing by task |
| `LocalIntentModel` | Foundation Models | Larger on-device models, adapters |
| `ToolHandler` | 30 tools | New integrations register tools; policy and journal apply automatically |
| `Card` | 10 transient card types | Images, documents, diagrams — added as card types and tool result types, not as a new UI paradigm |
| `PersistentStore` | AES-GCM files, Keychain key | CloudKit end-to-end-encrypted sync for memory and preferences |

Multimodal input (camera, documents) fits the same pipeline: an observation becomes part of the turn context, and results come back as cards. Nothing about the runtime assumes text-only.

## Latency budget

| Step | Target |
|---|---|
| Shortcut → listening tone + mic hot | < 150 ms |
| End of speech detected | 0.5–0.8 s after the last word (adaptive) |
| Fast-path understanding | < 2 ms |
| Tool execution (EventKit etc.) | 20–150 ms |
| First synthesized audio | < 250 ms |
| Cloud: first spoken sentence | ~1–2 s (streamed) |

## Testing

`swift test --package-path AsideKit` runs 83 tests in 15 suites: tokenizer, numbers, durations, ~50 temporal cases against a fixed clock and time zone, the grammar, control phrases and corrections, endpointing and echo rejection, policy tiers, the engine (grounded dates, dedupe, undo, honest failures, permissions, device authentication), tools, SSE parsing and content-block reconstruction, request construction, and **scripted end-to-end conversations** through the real runtime with fake speech I/O: create → correct → cancel, contact disambiguation by voice, barge-in, cloud tool calls governed locally, offline behavior, the Siri text path and discreet mode. CI builds both apps on every push.
