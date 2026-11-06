# Nikxel — Your Pixel Desktop Companion

A tiny pixel-art character that lives on your macOS desktop. Watches your AI
agents work, records meetings and writes the notes for you, surfaces today's
calendar events, and bubbles up reminders you added while you were away from
your laptop.

![Nikxel](nikxel_avatar.png)

## What it does

### Core (always on)

| Feature | Trigger |
|---|---|
| 🐱 **Floats on desktop** | Always visible above all windows |
| 🤔 **Thinking mode** | When Claude Code, OpenCode, Cursor, or any AI agent is working |
| 🎉 **Celebration jump** | When the agent completes a task |
| 🖱️ **Draggable** | Click and drag anywhere — stretches like mochi, springs back on release |
| ⌨️ **Overheat** | Turns red + steams when typing >30 WPM |
| 💭 **Thinking dots** | Animated "..." above head during agent processing |

### Recording & notes

| Feature | Trigger |
|---|---|
| 🎧 **Audio capture** | Double-click the avatar (or status bar → Start/Stop Recording). Captures mic + system audio. |
| 📋 **Notes mode** | For YouTube videos, lectures, podcasts. Mixes mic + system audio, transcribes, generates Summary / Key Points / Quotes / Open Questions. Output → `~/Documents/nikxel/notes/`. |
| 👥 **Meeting mode** | For calls. Transcribes mic ("Me") and system audio ("Others") separately, merges by timestamp, and generates a per-speaker MOM with Attendees / Decisions / Action Items. Output → `~/Documents/nikxel/meetings/`. |
| 🔇 **Mic mute** | Status bar → Mute Mic (or ⌘M). Recording continues; mic track is silent. |

Mode is set in the status bar under **Capture Mode** and persists across
launches. The active mode is shown on the "Start/Stop Recording" menu item.

### Reminders & calendar

| Feature | Source | Behavior |
|---|---|---|
| 📅 **Google Calendar pings** | Google Calendar | One-line bubble above the avatar ~2 minutes before each event. Connect via status bar → Connect Google Calendar… |
| 📋 **Apple Reminders bubbles** | Apple Reminders (iCloud, Siri, iPhone, Watch) | When you wake your Mac, new reminders you jotted while away bubble up. Tap a bubble to mark it complete. |

The Apple Reminders watcher uses a persistent "seen" set, so on first launch
it silently catches up to your existing backlog (no spam). After that, only
genuinely new reminders trigger bubbles. Refetches immediately when the Mac
wakes from sleep.

### Daily summary (end-of-day journal)

| Feature | Trigger |
|---|---|
| 📓 **Auto day-in-review** | Fires at 10pm daily (or on next launch if the Mac was asleep at 10pm). Manual: status bar → **Summarize Today Now**. |

Nikxel quietly samples your foreground app + window title every 15s through
the day (no keystrokes, no screen content — just app + window names), then
at 10pm stitches it together with:

- **Today's git activity** across every repo under `~/Desktop` — commits, uncommitted diff, current branch, recent commit history.
- **Today's meeting MOMs** you recorded (with their Summary sections).
- **Your Claude Code session prompts** — pulled from `~/.claude/projects/*/*.jsonl`, timestamped, grouped by project.
- **Your opencode session prompts** — queried from `~/.local/share/opencode/opencode.db` via `sqlite3`.

It then pipes the bundle to your chosen coding agent with a journaling prompt and writes a
narrative summary to `~/Documents/nikxel/daily/YYYY-MM-DD.md`. Because the
summary sees your literal prompts to AI agents, it names specific bugs and
features ("fixed the typing-linger bug, ~50-line diff in StateMachine.swift")
instead of generic ("edited Swift files").

Sleep gaps are capped at 5 min per sample so a night of sleep doesn't get
charged to whatever app was frontmost when you closed the laptop. Window
titles need Accessibility (the same grant the typing animation uses).

## Install (macOS)

Everything is built from source on your own Mac — there's no signed release
download, so macOS Gatekeeper never gets in the way.

### 1. Prerequisites

You need the Xcode Command Line Tools (ships the Swift compiler). Check:

```sh
xcode-select -p
```

If that errors, install them (a few GB, one time):

```sh
xcode-select --install
```

macOS 13.0 or later. Both Apple Silicon and Intel work — the build produces a
universal binary.

### 2. Clone and build

```sh
git clone https://github.com/nikhildhanda04/nikxel.git
cd nikxel
./setup.command
```

That compiles `Nikxel.app` and launches it. (You can also double-click
`setup.command` in Finder, or run `./build.sh && open Nikxel.app`.)

A pixel character appears on your desktop and a **Nikxel** item appears in the
menu bar.

### 3. Walk through the setup wizard

The wizard opens by itself on first launch. Reopen it any time from the menu
bar → **Setup Wizard…**. Four steps:

| Step | What it does |
|---|---|
| **Your avatar** | Keep the bundled character, or make one that looks like you — see [Make your own avatar](#make-your-own-avatar) below. |
| **Transcription tools** | Checks for `whisper` and `ffmpeg`, offering **Install with Homebrew** if either is missing. Downloads the speech model whisper.cpp needs, and sets the spoken language. Skippable — only the recording features need them. |
| **Connect WhatsApp** | Optional. Opens WhatsApp Web in an isolated Chrome profile; scan the QR with your phone and the wizard detects the login by itself. Only needed if you want Nikxel replying for you during meetings. |
| **Choose your coding agent** | Claude Code, OpenCode, or Codex — whichever writes your meeting notes and summaries. Ones you don't have are greyed out, with a copyable install command and a Re-check button. |

### 4. Grant permissions

macOS prompts for these as you first use each feature. Deny anything you don't
want; the rest keeps working.

- **Accessibility** — keystroke detection (the overheat / typing animation)
- **Microphone** — only while recording
- **Screen Recording** — required by ScreenCaptureKit to capture system audio
- **Reminders** — only for the Apple Reminders bubbles
- **Notifications** — for "Notes ready" / "MOM ready" toasts

### Updating

```sh
git pull
./build.sh
```

Your settings, prompts, and custom avatar live in `~/.nikxel/` and survive
rebuilds.

## Make your own avatar

The bundled sprite sheet works out of the box — this is entirely optional.

1. Menu bar → **Setup Wizard…** → **Your avatar**.
2. Click **Copy Gemini prompt**. (It's the contents of `sprite_prompt.txt`.)
3. Paste it into [Gemini](https://gemini.google.com) along with a photo of
   yourself, and follow its two steps: a 64×64 character first, then the full
   sprite sheet.
4. Click **Use my own sprite sheet…** and pick the PNG Gemini gave you.

Nikxel does the rest — it keys out the magenta background, finds the real grid
(Gemini's sheets are rarely the exact size it was asked for), scales every pose
by one shared factor so the character doesn't change size between states, and
installs it to `~/.nikxel/sprites.png`. The avatar swaps live, no restart.

A valid sheet is **10 rows × 4 columns** — one row per state, in this order:
idle, typing, thinking, done, dragging, pounce, petted, alert, recording, MOM
ready. If Gemini returns a different number of rows, the import refuses and
tells you the count it found, rather than installing sliced characters.

**Reset to default** puts the bundled avatar back.

## Optional — Recording dependencies

The audio recording / MOM pipeline shells out to a few CLI tools. None of
these are required for the pixel companion / agent watcher / reminders to
work — only for the Notes & Meeting features. The setup wizard checks for
`whisper` and `ffmpeg` and can install them for you.

| Tool | Purpose | Install |
|---|---|---|
| `whisper` (Python) or `whisper-cli` (whisper.cpp) | Speech-to-text | `brew install whisper-cpp` (recommended) or `pip3 install openai-whisper` |
| ggml speech model | whisper.cpp ships no model of its own | The wizard downloads `ggml-small.bin` (466 MB) to `~/.nikxel/models/` |
| `ffmpeg` | Mixes mic + system audio in Notes mode | `brew install ffmpeg` |
| A coding agent | Turns the transcript into Markdown notes | [Claude Code](https://claude.com/claude-code), [OpenCode](https://opencode.ai), or Codex — pick yours in the setup wizard |

Prompt templates live at `~/.nikxel/prompts/notes.md` and
`~/.nikxel/prompts/meeting.md` after the first run — edit them to taste; the
app won't overwrite once they exist.

## Languages — English, Hindi, Hinglish

Set the spoken language in the wizard (**Transcription tools** → *Spoken
language*). It is stored as `transcriptionLanguage` in
`~/.nikxel/settings.json`.

| Setting | Use it for |
|---|---|
| `en` (default) | English, and Hinglish where English words should stay English |
| `hi` | Mostly-Hindi speech |
| `auto` | Not recommended — see below |

**Hindi is always written in Latin letters**, never Devanagari, in both the
transcript and the summary: "main kal meeting mein shamil nahi ho paunga".
Whisper can't do that on its own (`-l hi` returns Devanagari and `-l en`
translates the meaning into English instead of writing the Hindi down), so
Nikxel transcribes in Hindi and romanizes the result itself.

One caveat: English words spoken inside Hindi come back spelled phonetically
("pheetchhar", "diployo"). The summary prompt tells your coding agent to
restore the normal spelling, so the MOM reads correctly even when the raw
transcript doesn't.

Auto-detect is offered but not recommended — measured against the base and
small models, it put Hindi into **Urdu** script, and on the small model it
turned plain English into Devanagari gibberish. Naming the language was
correct in every case tested.

Hindi needs the `small` model or better; `base` transcribes Hindi into Urdu
script even when told `-l hi`. The wizard downloads `small` for that reason.
Dropping a `ggml-medium.bin` or `ggml-large-v3-turbo.bin` into
`~/.nikxel/models/` upgrades it — Nikxel picks the largest model present.

## Connect Google Calendar (optional)

1. Google Cloud Console → APIs & Services → Credentials.
2. Enable the Google Calendar API.
3. Create OAuth client ID → "Desktop app". Download the JSON.
4. Save it to `~/.nikxel/google_creds.json`.
5. Status bar → **Connect Google Calendar…** to run the OAuth flow.

See in-app prompt for the full step-by-step. Calendar access is read-only.

## Customizing

### Change your avatar
Menu bar → **Setup Wizard…** → **Your avatar**. See
[Make your own avatar](#make-your-own-avatar).

### Switch which coding agent writes your notes
Menu bar → **Setup Wizard…** → **Choose your coding agent**.

### Add an AI agent to the "thinking" detection
Edit `src/OpenCodeMonitor.swift`, add the process name to the watched list,
then rebuild with `./build.sh`.

### Supported agents (autodetected)
opencode · claude · claude-code · codex · cursor · antigravity · kiro

## How it works

- **Floating window**: borderless, transparent, always-on-top NSWindow
- **Agent detection**: polls `ps aux` for known process names + CPU activity
- **Sprite rendering**: nearest-neighbor pixel scaling at 156×156
- **Keystroke detection**: macOS `CGEventTap` (needs Accessibility)
- **Audio capture**: `ScreenCaptureKit` for system audio + `AVAudioEngine` for mic, mixed via `ffmpeg` (Notes) or kept separate (Meeting)
- **Transcription**: shells out to `whisper` / `whisper.cpp`, plain text for Notes, SRT for Meeting (so timestamps can interleave speakers)
- **MOM generation**: shells out to your chosen agent (Claude Code / OpenCode / Codex) in headless one-shot mode; output is Markdown. The raw transcript is written to disk *before* generation runs, so a failed or timed-out summary never costs you the transcript.
- **Sprite import**: chroma-keys the magenta out, detects the row/column grid from background gaps instead of assuming an even division, and scales all 40 frames by one shared factor
- **Calendar / reminders**: Google Calendar v3 REST API on a 30 s poll; EventKit for Apple Reminders with `EKEventStoreChanged` notifications + `NSWorkspace.didWake` for wake-from-sleep refresh
- **Daily summary**: 15 s `NSWorkspace.frontmostApplication` + AX `kAXFocusedWindowAttribute`/`kAXTitleAttribute` polling → JSONL day-log; aggregated at 10 pm with `git log`/`git diff`, today's MOMs, Claude Code JSONL session transcripts, and `sqlite3` queries against the opencode database; narrative written by your chosen coding agent

## Where files live

| What | Where |
|---|---|
| Notes (YouTube / lectures / podcasts) | `~/Documents/nikxel/notes/` |
| Meeting MOM (per-speaker) | `~/Documents/nikxel/meetings/` |
| Daily summaries | `~/Documents/nikxel/daily/` |
| Raw day-activity log (JSONL) | `~/Library/Application Support/Nikxel/days/` |
| Prompt templates | `~/.nikxel/prompts/notes.md` & `meeting.md` |
| Speech models (whisper.cpp) | `~/.nikxel/models/` |
| Raw recordings (kept until processed) | `~/.nikxel/recordings/` |
| MOM workspace / last-run logs | `~/.nikxel/momworkspace/` |
| Google OAuth creds & token | `~/.nikxel/google_creds.json`, `~/.nikxel/google_token.json` |
| Your custom avatar (if you made one) | `~/.nikxel/sprites.png` |
| Settings (agent choice, name, language) | `~/.nikxel/settings.json` |

## Requirements

- macOS 13.0 or later (Reminders full-access API uses macOS 14+ when available, falls back gracefully on 13)
- Xcode Command Line Tools (`xcode-select --install`) — to build
- Optional: `whisper` + `ffmpeg` and a coding agent, for the recording / MOM
  features. The setup wizard installs the first two for you.

## License

MIT — use it, modify it, share it.

Built with Swift + AppKit. No telemetry. Recording, transcription, and MOM
generation all run locally on your Mac. Your desktop, your character, your
audio, your notes.
