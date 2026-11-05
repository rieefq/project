# Aside — Roadmap

V1 is deliberately narrow: the voice experience, a dependable set of everyday actions, and the foundations for trust. Each next step has to make Aside more useful without making it something you have to operate.

## Near term (V1.x)

- **Custom vocabulary.** Feed contact names and the user's music library to recognition (DictationTranscriber contextual strings) so names are heard right the first time.
- **More languages.** The fast-path grammar and temporal parser are English; the architecture takes per-locale grammar packs. Until then other languages route through the models.
- **Alarms.** Real wake-up alarms through AlarmKit on iOS once they can be made as dependable as the Clock app.
- **"What's playing around me."** ShazamKit recognition feeding "play this song on Spotify".
- **Leave-by nudges** for calendar events with locations — only where Calendar doesn't already provide them.
- **Mac Spotlight & Shortcuts actions** for the same intents as iOS.

## Next (V2)

- **Cross-device continuity.** End-to-end-encrypted CloudKit sync for memory and preferences; hand a conversation from Mac to iPhone.
- **Wake phrase.** A dedicated, low-power on-device keyword spotter with per-user enrollment — opt-in, Mac first, with a visible listening indicator and strict false-accept targets.
- **Multimodal moments.** "What's this?" with the camera, reading a document aloud, a chart when it explains better than words — each as a card and a tool result, not a new interface.
- **Semantic memory.** On-device embeddings behind the existing `MemoryStore` interface; consented learning of routines with a review step.
- **More integrations, carefully.** Mail drafting, Home, Notes export, ride and food services — each only when it can meet the reliability bar, each governed by the same policy tiers.

## Later

- **Multi-step autonomy.** Background workflows that plan, act, monitor and recover ("find a time with Sam next week, book it, and remind me the day before"), with checkpoints for anything consequential and a journal of every step.
- **Proactive help that earns its place.** Recognizing commitments and changes (a delayed flight, a meeting that moved) and offering one useful action — within the daily budget, quiet hours and back-off rules.
- **Purchases and payments** only with platform-native authorization (Apple Pay), explicit per-transaction confirmation, and spending limits the user sets.

## Measures that decide what ships

- Task success without repetition, and median time from end of speech to completed action.
- Correction rate ("no, I said…") and undo rate per capability.
- False activations, false interruptions, and accidental actions — targets near zero.
- Proactive suggestion acceptance vs. dismissal.
- How rarely people have to open Settings.
