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

It then pipes the bundle to `opencode` with a journaling prompt and writes a
narrative summary to `~/Documents/nikxel/daily/YYYY-MM-DD.md`. Because the
summary sees your literal prompts to AI agents, it names specific bugs and
features ("fixed the typing-linger bug, ~50-line diff in StateMachine.swift")
instead of generic ("edited Swift files").

Sleep gaps are capped at 5 min per sample so a night of sleep doesn't get
charged to whatever app was frontmost when you closed the laptop. Window
titles need Accessibility (the same grant the typing animation uses).

## Quick Start

### Step 1 — Create your character

1. Open `sprite_prompt.txt` → copy the **Step 1** prompt.
2. Paste into [Gemini](https://gemini.google.com) with a photo of yourself.
3. Save the output as `character.png`.

### Step 2 — Create your sprite sheet

1. Open `sprite_prompt.txt` → copy the **Step 2** prompt.
2. Paste into Gemini with `character.png` as the reference image.
3. Save the output as `final_sprite.png` in this folder.

The sprite sheet is now 10 rows × 4 columns (256×640) — adds Alert, Recording,
and MOM-ready poses on top of the original 7. If you previously generated a
7-row sheet, re-run Step 2 with the new prompt to get the new poses; otherwise
the new states will render blank.

### Step 3 — Run setup

Double-click `setup.command`. This runs `remove_magenta.py` to chroma-key the
magenta background out of your sprite sheet and installs it into the app,
then launches Nikxel.

### Step 4 — Grant permissions

On first launch you'll be prompted for a handful of macOS permissions, in
roughly this order:

- **Accessibility** — for keystroke detection (overheat / typing animation)
- **Microphone** — only used while recording
- **Screen Recording** — required by ScreenCaptureKit to capture system audio
- **Reminders** — only if you want the Apple Reminders bubbles
- **Notifications** — for "Notes ready" / "MOM ready" toasts

You can deny anything you don't want; the rest keeps working.

## Optional — Recording dependencies

The audio recording / MOM pipeline shells out to a few CLI tools. None of
these are required for the pixel companion / agent watcher / reminders to
work — only for the Notes & Meeting features.

| Tool | Purpose | Install |
|---|---|---|
| `whisper` (Python) or `whisper-cli` (whisper.cpp) | Speech-to-text | `pip3 install openai-whisper` or `brew install whisper-cpp` |
| `ffmpeg` | Mixes mic + system audio in Notes mode | `brew install ffmpeg` |
| `opencode` | Runs the prompt → markdown step | See [opencode.ai](https://opencode.ai) |

Prompt templates live at `~/.nikxel/prompts/notes.md` and
`~/.nikxel/prompts/meeting.md` after the first run — edit them to taste; the
app won't overwrite once they exist.

## Connect Google Calendar (optional)

1. Google Cloud Console → APIs & Services → Credentials.
2. Enable the Google Calendar API.
3. Create OAuth client ID → "Desktop app". Download the JSON.
4. Save it to `~/.nikxel/google_creds.json`.
5. Status bar → **Connect Google Calendar…** to run the OAuth flow.

See in-app prompt for the full step-by-step. Calendar access is read-only.

## Customizing

### Make your own character
1. Re-do Steps 1–2 with a new photo.
2. Replace `final_sprite.png` with the new output.
3. Re-run `setup.command`.

### Add an AI agent to detect
Edit `src/AgentMonitor.swift`, add the process name to `agentNames`, then
rebuild with `./build.sh`.

### Supported agents (autodetected)
opencode · claude · claude-code · codex · cursor · antigravity · kiro

## How it works

- **Floating window**: borderless, transparent, always-on-top NSWindow
- **Agent detection**: polls `ps aux` for known process names + CPU activity
- **Sprite rendering**: nearest-neighbor pixel scaling at 156×156
- **Keystroke detection**: macOS `CGEventTap` (needs Accessibility)
- **Audio capture**: `ScreenCaptureKit` for system audio + `AVAudioEngine` for mic, mixed via `ffmpeg` (Notes) or kept separate (Meeting)
- **Transcription**: shells out to `whisper` / `whisper.cpp`, plain text for Notes, SRT for Meeting (so timestamps can interleave speakers)
- **MOM generation**: shells out to `opencode` with a stdin prompt; output is Markdown
- **Calendar / reminders**: Google Calendar v3 REST API on a 30 s poll; EventKit for Apple Reminders with `EKEventStoreChanged` notifications + `NSWorkspace.didWake` for wake-from-sleep refresh
- **Daily summary**: 15 s `NSWorkspace.frontmostApplication` + AX `kAXFocusedWindowAttribute`/`kAXTitleAttribute` polling → JSONL day-log; aggregated at 10 pm with `git log`/`git diff`, today's MOMs, Claude Code JSONL session transcripts, and `sqlite3` queries against the opencode database; narrative written by `opencode`

## Where files live

| What | Where |
|---|---|
| Notes (YouTube / lectures / podcasts) | `~/Documents/nikxel/notes/` |
| Meeting MOM (per-speaker) | `~/Documents/nikxel/meetings/` |
| Daily summaries | `~/Documents/nikxel/daily/` |
| Raw day-activity log (JSONL) | `~/Library/Application Support/Nikxel/days/` |
| Prompt templates | `~/.nikxel/prompts/notes.md` & `meeting.md` |
| Raw recordings (kept until processed) | `~/.nikxel/recordings/` |
| MOM workspace / last-run logs | `~/.nikxel/momworkspace/` |
| Google OAuth creds & token | `~/.nikxel/google_creds.json`, `~/.nikxel/google_token.json` |

## Requirements

- macOS 13.0 or later (Reminders full-access API uses macOS 14+ when available, falls back gracefully on 13)
- Python 3 with Pillow (`pip3 install Pillow`) — for sprite setup
- Optional: `whisper`, `ffmpeg`, `opencode` for the recording / MOM features

## License

MIT — use it, modify it, share it.

Built with Swift + AppKit. No telemetry. Recording, transcription, and MOM
generation all run locally on your Mac. Your desktop, your character, your
audio, your notes.
