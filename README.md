<p align="center"><img src="docs/icon.png" width="160" alt="Aside"></p>

# Aside

**A voice-first personal agent for Mac and iPhone.** Summon it, say what you want, and it gets done.

> ⌥ Space — "Remind me to change my toothbrush in 30 days."
> *Soft tone.* "Okay, I'll remind you to change your toothbrush on December 5th."
>
> "Actually, make it Saturday morning."
> "Okay, moved it to Saturday at 9 AM."

Aside isn't a chatbot or a dashboard. There's no chat box, no transcript to scroll and nothing to organize — just a filament of light while it listens, thinks and speaks, one line of caption, and a small card when a decision or a detail needs your eyes. Everyday requests are understood on the device in about a millisecond; open questions go to Claude when you allow it. Anything that affects other people, or can't be undone, waits for your tap.

## What it does in V1

Reminders · your schedule · timers · notes and commitments · memory you control · Apple Music and Spotify · weather · places and travel time · messages and calls (you send) · time, math and conversions · open questions with web search.

It handles the way people actually talk: "stop", "cancel that", "never mind", "change it to tomorrow", "make it 20 minutes", "what are you doing?", "undo that", interrupting while it speaks, and choosing between two Sams by saying "the second one".

## Repository

```
AsideKit/          Platform-independent core (Swift package, 83 tests)
  Language/        Tokenizer, number words, durations, temporal parser, spoken formatting
  Understanding/   Fast-path grammar, control commands, corrections, endpointing, echo guard
  Actions/         Tool registry, policy engine, action engine, journal, tools
  Reasoning/       Claude reasoner (streaming, tools, web search), persona, on-device intent frames
  Memory/          On-device memory with recall, consent, export
  Runtime/         The conversation runtime and speech I/O protocols
Apps/
  Shared/          Audio engine, speech, platform services, presence UI, cards, settings
  macOS/           Menu bar agent, presence panel, hot keys, Mac communication
  iOS/             Presence screen, settings sheet, iPhone communication
  Intents/         Siri, Shortcuts, Action button intents
  Controls/        Control Center / Lock Screen control (WidgetKit extension)
project.yml        XcodeGen project spec
docs/              Design, architecture, platforms, trust, roadmap
```

## Building

Requirements: Xcode 26 or later, macOS 26 / iOS 26 SDKs, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
```

```bash
xcodegen generate
```

```bash
open Aside.xcodeproj
```

Set your team in the project (or `DEVELOPMENT_TEAM` in `project.yml`), enable the **WeatherKit** and **MusicKit** app services for your App IDs, and run `Aside-macOS` or `Aside-iOS`. For Spotify, create a Spotify app with redirect URI `aside://spotify-callback` and set `ASIDE_SPOTIFY_CLIENT_ID`. For open questions, add a Claude API key (or an organization relay) in Settings › Intelligence; without one, Aside runs entirely on device.

Run the core tests:

```bash
swift test --package-path AsideKit
```

CI (`.github/workflows/ci.yml`) runs the tests and builds both apps on every push.

## Documentation

- [Product & interaction design](docs/design.md) — principles, turn-taking, interruptions, brevity, discretion, the visual identity, V1 capabilities
- [Architecture](docs/architecture.md) — modules, routing, policy, audio, reasoning, extensibility, latency, testing
- [Platform integration](docs/platforms.md) — what macOS and iOS allow, and how Aside uses it
- [Privacy, security & control](docs/trust.md) — data flows, storage, consent tiers, memory controls
- [Roadmap](docs/roadmap.md)
