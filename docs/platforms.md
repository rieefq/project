# Aside — Platform Integration

Aside is built for what macOS and iOS actually allow third-party apps to do, and says so plainly where they don't.

## macOS

| Element | Implementation | Why |
|---|---|---|
| Presence | `LSUIElement` agent; menu bar item; borderless, non-activating `NSPanel` at `.statusBar` level, joins all Spaces and full-screen apps | Never steals focus or keyboard input from what you're doing; no Dock icon, no window to manage |
| Summon | Carbon `RegisterEventHotKey` (⌥Space by default, presets in Settings) with press/release events | System-wide without Accessibility permission, and it never observes other keystrokes |
| Push-to-talk vs hands-free | Hold > 0.35 s = push-to-talk (ends on release); tap = hands-free with adaptive endpointing; press again to finish | One shortcut, two natural behaviors |
| Cancel | Esc is registered as a hot key **only while Aside is active** | So it never steals Esc from other apps |
| Startup | `SMAppService.mainApp` toggle | Opt-in, managed in System Settings › Login Items |
| Messages / calls | `NSSharingService(.composeMessage)` pre-filled; `tel:` / `facetime:` handoff | The system UI is the confirmation; Aside reports "ready to send" |
| Sandbox | App Sandbox + hardened runtime; entitlements for microphone, network client, calendars/reminders, contacts, location, WeatherKit | Least privilege |

**Wake word on the Mac.** It is technically possible to keep the microphone open and transcribe continuously. Aside doesn't ship that in V1: it would keep the microphone indicator lit all day, cost real battery and CPU with a general-purpose recognizer, and fire falsely. A wake word belongs behind a dedicated, low-power, on-device keyword spotter with per-user enrollment; the `SpeechInput`/activation seams are built for it. Until then the shortcut and menu bar are the ways in, and Settings says why.

## iOS

| Element | Implementation | Notes |
|---|---|---|
| Presence | Full-screen dark field with the filament; tap to talk, hold to keep talking; small settings button | Opening Aside is already the start of a conversation |
| Siri | `AskAsideIntent` (`supportedModes: .background`) with a `requestValueDialog`; App Shortcut phrases "Ask Aside" / "Tell Aside" | Hands-free from anywhere, including the Lock Screen, AirPods and CarPlay: Siri owns the wake word, Aside does the work and Siri speaks the reply. Free-form text can't be part of the trigger phrase itself, so Siri asks "What do you need?" |
| Action button / Shortcuts / Back Tap | `ListenIntent` (`OpenIntent`) via App Shortcuts | Opens directly into listening |
| Control Center & Lock Screen | `ControlWidgetButton` in a WidgetKit extension running `ListenIntent` | The intent is compiled into both app and extension, as required for controls that open their app |
| Background | `UIBackgroundModes: audio` | A conversation that started in the foreground can finish if you switch apps or lock the phone. Aside does **not** listen in the background between interactions — iOS doesn't permit it, and it shouldn't. |
| Audio session | `.playAndRecord`, `.defaultToSpeaker`, `.allowBluetoothHFP` (AirPods mic), `.allowBluetoothA2DP`, `.duckOthers`; deactivated with `notifyOthersOnDeactivation` | Your music ducks under Aside and comes back afterwards |
| Messages / calls | `MFMessageComposeViewController` pre-filled; `tel://` | You see the recipient and exact text and tap Send |
| Notifications | Time-sensitive local notifications for timers; categories with actions | Timers fire even if Aside was terminated |
| Locked device | App Intents run with the device's protection; consequential requests from Siri return "Open Aside to confirm that." | Confirmation requires the device in hand |

**Wake word on iPhone.** Third-party apps can't run an always-on wake word: background microphone access ends when the interaction ends, and holding the microphone open would be both an App Store violation and a privacy problem. The honest, reliable alternative is "Hey Siri, ask Aside", the Action button and the Control Center control.

## Audio routes and environments

- AirPods, headphones, Bluetooth and CarPlay routes are detected; personal details can be limited to private audio (Settings › Voice).
- Route changes and system interruptions (calls, Siri, alarms) stop capture cleanly and restore the user's audio; the next activation starts fresh.
- Voice processing provides echo cancellation and noise suppression; the energy VAD adapts its noise floor so noisy rooms don't hold turns open, and the endpointer's 30-second cap prevents runaway capture.
- Low recognition confidence and clarifications are handled by asking one short question rather than guessing.

## Connectivity

Everything in the fast path — reminders, timers, calendar, notes, memory, music control, time and math — works offline. Open questions say "I'm offline right now…" instead of hanging. When cloud understanding is off or unavailable, the on-device foundation model (Apple Intelligence devices) still maps unusual phrasings to local actions.

## Accessibility

- VoiceOver labels describe the presence state ("Aside is listening"); cards are accessible elements with readable labels; buttons have keyboard shortcuts on the Mac (Return confirms, Esc cancels).
- Reduce Motion keeps the filament still (brightness only).
- Captions can stay on for people who prefer reading; discreet mode gives a fully silent, text-and-sound experience.
- Voice, rate and volume follow the user's choices, including Personal Voice.

## Requirements

- iOS 26 / iPadOS 26 and macOS 26 (SpeechAnalyzer, Foundation Models, Liquid Glass, current App Intents).
- Apple Intelligence-capable devices for the on-device model (optional — everything else works without it).
- WeatherKit and MusicKit capabilities on the App ID; a Spotify client ID for Spotify (optional).
