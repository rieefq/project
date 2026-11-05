# Aside — Product & Interaction Design

## The idea

Aside is a personal AI agent that lives in your Mac and iPhone and does things when you say them. It is not a chatbot, a dashboard or a wellness companion. You summon it, say what you want in your own words, and it takes care of it — usually in about a second, often without saying more than a few words.

The measure of success is how little you notice it: **the shortest possible distance between an intention and its fulfilment.**

## Principles

1. **Act, don't chat.** The default output is a done thing, not a paragraph. Straightforward requests get straightforward acknowledgments.
2. **Silence is a valid answer.** When the result is self-evident — music starts, a timer chimes on — a sound is enough.
3. **Never claim what you haven't confirmed.** Success is spoken only after the system reports it. A message "is ready to send" until the platform says it was sent.
4. **The user stays in charge of anything consequential.** Messages, calls, changes others will see and deletions are shown and approved with a tap or device authentication — never by voice alone.
5. **Complexity lives behind the scenes.** Routing between grammar, on-device and cloud models, policy checks, retries and deduplication are invisible. There is nothing to configure before the first request.
6. **Personal, but restrained.** Aside remembers what you ask it to, asks before remembering anything else, and makes all of it reviewable and deletable.
7. **Speak up rarely.** Proactivity is a privilege with a small daily budget, quiet hours and permanent back-off when ignored.
8. **Be honest about limits.** If iOS doesn't allow a wake word for third-party apps, Aside says so and offers the best real alternative.

## What V1 is not

There is no chat box, no message bubbles, no scrolling transcript, no conversation history browser, no prompt library, no task board, no widgets wall and no metrics. The only things on screen are a light, one line of caption, and at most two small cards that disappear by themselves.

## The interaction model

### Summoning

| Platform | Ways in | Notes |
|---|---|---|
| Mac | **⌥ Space** (configurable), menu bar click | Hold to talk (push-to-talk) or tap and just speak. Tap again to finish early. Esc cancels. Works over full-screen apps; never steals focus. |
| iPhone | Tap the screen, hold to talk, **Action button**, **Control Center / Lock Screen control**, **"Ask Aside"** via Siri, Back Tap | Siri owns the wake word on iOS; through App Intents Aside answers hands-free without opening. |

Activation plays a soft rising two-tone and the presence appears. If nothing is said within six seconds, Aside fades out without a word.

### Turn-taking

Aside decides when you've finished speaking with an **adaptive endpointer** instead of a fixed timeout:

- a complete, confidently-understood command ends after ~0.5 s of silence;
- a sentence that trails off on "to", "and", "at"… gets ~1.7 s, so "remind me to… call the dentist" isn't cut off;
- otherwise ~0.8 s.

When Aside asks a question ("Which Sam — Sam Lee or Sam Patel?") the microphone stays open for the answer; no re-summoning. You can answer before it finishes asking ("the second one") and it stops talking; an answer made only of words the question itself contains ("Sam Patel") waits until the question ends, so Aside never mistakes its own voice for yours.

### Interruptions and corrections

The microphone stays on while Aside speaks, with acoustic echo cancellation, so you can talk over it. An **echo guard** ignores recognized words that are actually Aside's own voice leaking back.

| You say | Aside does |
|---|---|
| "Stop" | Stops talking immediately. If nothing else is happening and music is playing, pauses the music. |
| "Cancel that" | Cancels what's in flight — or, if it already finished, undoes it ("Okay, I removed that reminder."). |
| "Never mind" | Drops everything with a soft falling tone. No speech. |
| "Wait" / "Pause" | Pauses speech and listens. "Go on" resumes. |
| "Change it to tomorrow", "Make it 20 minutes", "No, I said 3 PM", "Rename it to…" | Applies the correction to what was just done, keeping what wasn't changed (moving a 5 PM reminder to tomorrow keeps 5 PM). |
| "Undo that" | Reverses the last action from the last 15 minutes. |
| "What are you doing?" | Describes the current activity, or what it's waiting for. |
| "What did you just do?" | Reads back the last action from the activity journal. |
| "Repeat that", "Louder", "Slower", "Be discreet" | Exactly that. |

Control phrases are recognized locally in every state, offline.

### Brevity and silence

Every action produces a **speech plan** with minimal, balanced and detailed variants; the user's verbosity picks one. For example, "Remind me to change my toothbrush in 30 days":

- minimal: "Got it, on December 5th."
- balanced (default): "Okay, I'll remind you to change your toothbrush on December 5th."
- detailed: "Okay, I'll remind you to change your toothbrush in 30 days — that's Saturday, December 5th."

Read-backs switch to the second person ("your toothbrush"), so the user hears that they were understood. Playback controls, pausing music and confirmed timers rely on sound alone where that's enough.

### Discretion

Spoken output follows a **speech privacy** setting:

- *Always speak* (default).
- *Personal details only on headphones*: on a speaker, Aside says "Here you go" and shows the agenda card instead of reading event titles aloud.
- *Discreet*: nothing is spoken; replies appear as a short caption and sounds remain. "Be discreet" / "You can talk again" toggles it by voice.

### Visual moments

The visual layer is the minimum that keeps you informed and in control:

- **The presence** (always, while active).
- **Live caption** (optional): one line — your words while you talk, Aside's while it answers.
- **Cards**, only when they add something voice can't: confirmation of a consequential action (who, what, consequence, Confirm/Cancel); a choice between people or items; a compact agenda; a small map; weather with attribution; now playing; a permission hint; web sources; an error with a way forward.

Cards are small, glass-backed, and leave by themselves after a few seconds unless they need a decision. There is never more than two.

## Visual identity: the filament

Aside's presence is a **single horizontal filament of light** — not an orb, not a face, not a screen-edge glow.

| State | Filament | Tint |
|---|---|---|
| Listening | Widens and ripples with your voice | Clear sky (#8FCCFF) |
| Thinking | Thin and still; a bead of light travels along it | Soft violet (#B8A8FF) |
| Speaking | Pulses from the centre with Aside's voice | Warm light (#FFD4A3) |
| Waiting for you | Steady, with a slow drifting highlight | Mint (#9EF2D6) |
| Problem | Brief amber | Amber (#FFA378) |

The palette is desaturated light on dark glass: premium and quiet rather than neon. On the Mac the filament sits in a small glass capsule under the menu bar, over whatever you're doing; on iPhone it floats on a deep graphite field. Motion is restrained and respects Reduce Motion (the filament holds still and only brightness changes). Earcons are synthesized in-app: short, soft sine tones designed as a family (rising for listening, a bright tick for success, falling for cancelled, a low pair for failure).

## Personality

Personality is expressed through wording and timing, never by pretending to be human. Three presets — **Warm** (default), **Crisp**, **Playful** — plus the user's own instructions and preferred name. Aside describes itself as an AI assistant when asked, doesn't flatter, doesn't encourage dependence, and doesn't coach.

## Capabilities in V1

Chosen by how often they're needed × how much friction they remove × how reliably they can be delivered today:

| Area | Examples | How it's delivered |
|---|---|---|
| Reminders | "Remind me to change my toothbrush in 30 days", "every Monday at 8", "what do I need to do today?", "mark buy milk done" | EventKit (Apple Reminders) |
| Schedule | "What's on my schedule tomorrow?", "When's my next meeting?", "Am I free Friday afternoon?", "Add lunch with Sam Friday at noon" | EventKit (Calendar). Changes to events with attendees need confirmation. |
| Timers | "10 minute pasta timer", "how long is left?", "make it 20 minutes" | Scheduled time-sensitive notifications; work even if Aside isn't running |
| Notes & commitments | "Note that the gate code is 4412", "I parked on level 3", "where did I park?" | Aside's own encrypted on-device memory |
| Memory | "Remember that Alex is allergic to peanuts", "what do you know about me?", "forget that" | Same store; reviewable, exportable, deletable |
| Music | "Play Blinding Lights on Spotify", "pause", "skip" | MusicKit (Apple Music) and the Spotify Web API |
| Weather | "Do I need an umbrella tomorrow?" | WeatherKit, with attribution |
| Places & travel | "How long to get to SFO?", "directions to the nearest pharmacy" | MapKit |
| Messages & calls | "Text Sam I'm running late", "call mom" | The system compose sheet and call prompt — the user taps Send/Call |
| Quick answers | "What time is it in Tokyo?", "18% of 64", "5 km in miles" | Computed locally, exactly |
| Open questions | "Why do cats purr?", "is the Lisbon museum open Mondays?" | Claude (with web search) when cloud understanding is on |

**Deliberately not in V1:** alarms that must ring through silent mode (Aside offers a reminder instead, and says why); purchases, payments, transfers, posting, account changes (refused politely); ambient song recognition; camera, image and document workflows; dashboards of any kind. Each would either be unreliable today or pull the product toward an interface it shouldn't have.
