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
| 📅 **Google Calendar pings** | Google Calendar | One-line bubble above the avatar ~2 minutes before each event. Connect via status bar → Connect Google Account… |
| ✅ **Action items → Google Tasks** | Your meeting summaries | After a meeting summary, offers to push its action items to Google Tasks and agreed follow-ups to your calendar as events with a Meet link. Always shows the list first. |
| 📋 **Apple Reminders bubbles** | Apple Reminders (iCloud, Siri, iPhone, Watch) | When you wake your Mac, new reminders you jotted while away bubble up. Tap a bubble to mark it complete. |

The Apple Reminders watcher uses a persistent "seen" set, so on first launch
it silently catches up to your existing backlog (no spam). After that, only
genuinely new reminders trigger bubbles. Refetches immediately when the Mac
wakes from sleep.

### Daily summary (end-of-day journal)

| Feature | Trigger |
|---|---|
| 📓 **Auto day-in-review** | Fires at 10pm daily (or on next launch if the Mac was asleep at 10pm). Manual: status bar → **Summarize Today Now**. |
| 🌙 **Digest bubble** | When the summary lands, a bubble pops above the avatar with the day in one line — see [bubbles above the avatar](#bubbles-above-the-avatar). |

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

## Bubbles above the avatar

Nikxel talks to you through a speech bubble above its head rather than a modal
dialog, so nothing steals focus mid-sentence:

| When | Bubble |
|---|---|
| A meeting summary finishes | 📄 **Minutes ready** + the first three action items from the note itself |
| Notes finish | 📄 **Notes ready** + the first key points |
| The 10pm day summary is written | 🌙 **Today, in short** — `3h 20m coding · 2 meetings · 41 messages` |
| Generation, transcription or recording fails | ⚠️ the reason, plus what to do about it |

Click a bubble to act on it: a ready one opens the note, the digest opens the
day summary, a failure opens that run's logs (or the Screen Recording settings,
for a recording error).

Timing differs by kind, deliberately. A "ready" bubble goes after ~25 seconds.
The 10pm digest stays ten minutes, because it fires when nobody is watching and
has to still be there when you come back. **Failures stay until you click
them** — a failure costs nothing (the transcript is written to disk *before*
generation runs, and **Regenerate Unfinished Summary** picks it back up), but
it shouldn't scroll past unseen either.

Errors used to be modal alerts. They aren't any more — the alert is reserved
for the two places Nikxel actually needs an answer from you: confirming a
regenerate, and confirming what gets sent to Google.

The digest line is computed from the day log, not written by the model: coding
time is foreground time in editors, terminals and IDEs; meetings are the MOMs
you recorded today; messages are WhatsApp previews seen through the day. Parts
that are zero are left out, so a day with no coding reads `4 meetings ·
63 messages`. A day with nothing in it gets no bubble at all.

> **Note on the Liquid Glass bubbles.** The older calendar / reminder /
> "someone is texting" bubbles are `NSGlassEffectView`s, which only exist in
> the macOS 26 SDK — on any other SDK they silently render nothing, even on
> macOS 26 itself. The bubbles above are plain CoreGraphics and show up on
> every build.

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
| **Connect WhatsApp** | Optional. Opens WhatsApp Web in an isolated browser profile; scan the QR with your phone and the wizard detects the login by itself. Needs a Chromium-based browser installed — **Chrome, Brave, Edge, Chromium, Vivaldi or Opera**; it tells you so instead of waiting forever if you have none. Only needed if you want Nikxel replying for you — during meetings, or all day (see *When the WhatsApp bot replies*). |
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
cd nikxel
git pull
./setup.command
```

That's the whole thing — same command as the install. There's no in-app
updater, so nothing tells you a new version exists; to see what you'd be
getting, `git fetch && git log --oneline HEAD..origin/main`.

Lost your clone, or installed by downloading the repo as a ZIP? Clone it
properly once (`git clone https://github.com/nikhildhanda04/nikxel.git`) and
run `./setup.command` from there. Your settings in `~/.nikxel/` are picked up
by whichever copy you launch, so nothing is lost — delete the old folder
afterwards so you don't run a stale build by accident.

The build output (`Nikxel.app/Contents/MacOS/Nikxel` and its signature) is not
tracked by git, so rebuilding never leaves changes that block the next pull.

`setup.command` quits the running copy before rebuilding, then relaunches it.
That quit matters: Nikxel reads your prompt templates and settings once, at
launch, so a copy left running keeps behaving like the old version even after
a successful rebuild. `./build.sh` alone updates the binary but not the
running process.

Your settings, prompts, and custom avatar live in `~/.nikxel/` and survive
rebuilds. Prompt templates are the one thing that updates itself: each shipped
default carries a version tag, and a copy of yours that is behind is replaced
on the next launch. Edit the prompts freely — but delete the
`<!-- nikxel-prompt vN -->` line at the top if you want yours left alone
permanently.

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

## If a summary gets interrupted

Double-clicking the avatar while it's still writing your notes no longer
starts a new recording — it says *"Still writing your notes…"* instead. The
menu bar's **Start/Stop Recording** is unguarded, so recording during a
summary is still possible when you actually mean it.

If a summary never finishes — you quit the app, the Mac slept, the agent
failed — the transcript is already on disk (saved *before* generation runs)
and a marker records that a summary is owed. Menu bar → **Regenerate
Unfinished Summary…** re-runs your agent over that transcript. Nikxel also
flags leftovers on launch.

Each run now gets its own folder under `~/.nikxel/momworkspace/<timestamp>/`.
Previously every run wrote to the same `last_*.log` files, so two overlapping
runs destroyed each other's logs.

## What a meeting summary contains

Every MOM has the same sections, in this order:

**Summary** · **Speakers** · **Per-Speaker Highlights** · **Decisions** ·
**Blockers & Risks** · **Open Questions** · **Action Items** ·
**Follow-Up Meetings** · **Agent Prompts**

…unless you've picked a different [summary template](#summary-templates) or
written your own. Three of these are worth knowing about.

### Speakers

Nikxel records two audio channels, not two people: your microphone (`Me`) and
everything coming out of your speakers (`Others`) — which is *everyone else on
the call, mixed together*, however many of them there are. Separating them back
out is the summary's first job, using self-introductions, who gets addressed by
name, handoffs, who answers which questions, and the gaps between turns.

People it can name, it names. People it can't, it labels `Speaker 2`,
`Speaker 3` and keeps those labels consistent through the whole document. When
it genuinely can't tell two voices apart it says so rather than guessing — an
honest *"could not be separated reliably"* beats a confident wrong name.

Your own name comes from the setup wizard, or failing that from your macOS
account. It's `userName` in `~/.nikxel/settings.json`.

### Agent Prompts

Any action item that is actual software work also gets written as a
ready-to-paste prompt for your coding agent, in a fenced block you can copy in
one go:

> ### Webhook consumer retries and idempotency — Priya
> ```
> Add retry handling and idempotency to the webhook consumer so transient
> downstream failures stop dropping events…
>
> Background: … Required changes: … Done when: …
>
> Ask about these before starting:
> - Which cron job is it, and where does it live? Don't guess.
> ```

Each prompt carries the background from the meeting, the specific changes
asked for, how to tell it's done, and — importantly — whatever the meeting
*left unspecified*, listed as questions for the agent to ask first. It will
not invent file paths, function names, endpoints or library versions; if the
discussion said "that cron job", the prompt says "that cron job" and asks.

Non-code tasks (chasing approvals, booking rooms, making calls) are skipped
here — they stay in **Action Items** where they belong. A meeting with no
engineering work just gets *"None"*.

### Follow-Up Meetings

Meetings the call actually agreed to schedule — *"let's do a design review
Thursday at 3"* — with a real date, a real time and a length:

> - **Design review** — When: 2026-11-12 15:30 — Duration: 45 min — With: Priya, Rohan

A follow-up agreed for "Thursday afternoon" with no time named is written as
`Not specified` on purpose. Nikxel will not pick a plausible hour: a calendar
entry at an invented time is worse than no entry. Vague intentions ("we should
sync more often") and meetings that already exist are left out entirely.

These are what [Google Calendar sync](#connect-your-google-account-optional)
turns into real events.

### Summary templates

A developer, an HR lead, a project manager and a founder want genuinely
different things out of the same call. Menu bar → **Summary Template** picks
which shape you get:

| Template | What it changes |
|---|---|
| **Default (balanced)** | The built-in structure, unchanged. |
| **Developer** | Keeps Agent Prompts. Records the rejected options and why. Preserves endpoint paths, table names, flags and versions verbatim. Adds **Technical Context** for the numbers and constraints that aren't tasks, and **Review Notes** if a PR was discussed. Separates work that can start from work waiting on a decision. |
| **Project Manager** | Opens with **Status at a Glance**. Demands an owner and a date on every item, and lists the ones that have neither under **Gaps**. Adds **Scope & Timeline Changes** (before → after) and **Dependencies**. Orders blockers by how many people they're holding up. |
| **HR** | Drops Agent Prompts. Adds **Commitments Made** — anything promised to a person, quoted in the words it was made in — and **Concerns Raised**, in the person's own words. Renames Per-Speaker Highlights to Per-Person Notes. Quotes contested wording exactly, and explicitly won't diagnose anyone or infer anything personal that wasn't volunteered. |
| **Co-founder** | Decision-first. Puts **Needs a Decision From Me** right under the summary. Adds **Money** (every figure with its units, never rounded) and **Commitments to Outsiders**. Records what was traded away, not just what was chosen. Drops Agent Prompts and keeps the whole thing short. |

Every one of them is a plain text file in `~/.nikxel/templates/`, holding
nothing but instructions:

```
Drop the Agent Prompts section entirely.
Rename "Per-Speaker Highlights" to "## Per-Person Notes".
Add a "## Commitments Made" section near the top: anything promised to a
person — compensation, title, leave, timelines, headcount, training…
```

So you can edit any of them, and write your own:

- **Edit "<name>"…** opens the active template in your editor. Lines starting
  with `#` are ignored, so the notes in the file are safe to leave there.
- **New Template…** names a new one — "Client Calls", "Design Review", "Board"
  — either blank or copying the one you're on.
- **Reset "<name>" to Default…** restores a built-in template to the shipped
  version. Nikxel never overwrites a template you've edited, so this is the
  only way back.
- **Delete "<name>"…** removes one of yours and falls back to Default.

Changes take effect on your next recording.

Templates are an *overlay* on the prompt, not a replacement for it — which is
why they're a dozen lines rather than two hundred, and why they keep working
when the speaker-separation rules improve. If you want to rewrite the whole
thing, `~/.nikxel/prompts/meeting.md` is still there.

Three things a template cannot override:

- **Inventing content.** Attendees, decisions, owners, numbers, dates, file
  paths and identifiers still come only from what was actually said. A section
  with nothing to fill it gets `- None.`
- **The two heading names** `## Action Items` and `## Follow-Up Meetings`, which
  are read back when [sending tasks to Google](#sending-a-meetings-tasks-to-google).
  Everything else can be renamed.
- **Instructions that don't fit.** A template is written with meetings in mind;
  anything in it that makes no sense for a lecture or a podcast is ignored.

If you were using `~/.nikxel/summary_style.txt` from before templates existed,
whatever you wrote in it is carried over as a template called **My Style** and
selected for you.

## When the WhatsApp bot replies

Menu bar → **WhatsApp Bot**. Everything here is off or conservative by default;
upgrading never puts your bot on the air more than it already was.

| Setting | Options |
|---|---|
| **Auto-Replies** | On / Off. The master switch — off means silent everywhere. |
| **Reply…** | **Only during meetings** (default) · **Any time, if unanswered for N min** · **Any time, immediately** |
| **Group Chats** | **Off** (default) / **Only When Tagged** |
| **Draft Only (don't send)** | Off (default) / On |
| **Quiet Hours** | **10pm–8am** (default) / Off |
| **Knows What You're Working On** | On (default) / Off |
| **Tasks from Chats** | On (default) / Off |
| Edit Bot Personality… · Edit Trusted Contacts… · Edit Never-Reply List… | opens the file |

**Only during meetings** is the original behaviour: you're visibly busy, so a
stand-in reply beats silence, and it goes out within seconds.

**Any time, if unanswered** is the one to pick if you want the bot on all day.
It waits until a message has sat genuinely unread for `waUnattendedMinutes`
(5 by default, editable in `~/.nikxel/settings.json`, max 120) before saying
anything — so you always get first refusal, and it only steps in once it's
clear nobody else is going to. Reading the chat yourself at any point cancels
the pending reply. During a meeting it still answers immediately: telling
someone you're in a meeting five minutes late is worse than useless.

**Any time, immediately** has no gate at all. The bot will routinely beat you
to the reply.

### Groups

Off by default, and deliberately not a plain on/off: when enabled, only
messages that **@-mention you** are answered. Most group traffic isn't
addressed to you, and a bot that replies to all of it is the fastest way to get
muted by everyone you know.

Group detection reads the sidebar row *without opening the chat* — opening one
marks it read and hides it from your phone, which is exactly the damage the
filter exists to prevent.

The signal is WhatsApp's own markup. A group row renders its last message as
*sender*, a literal `:&nbsp;` separator, then the text; a one-to-one row goes
straight to the text. That separator is the test, and the sender's name comes
out of it for free. Verified against a real chat list: 4 groups and 18
one-to-one chats, all correctly classified.

Once a chat is open there's a second, authoritative signal — WhatsApp labels
the message box *"Type a message to **group** Warrior Tennis"* — which backs up
the sidebar check before any reply goes out. That qualifier is English, so under
a non-English WhatsApp UI only the sidebar check (which is language-independent)
applies.

### What the bot can read

Replies are written from the actual messages, read out of the open conversation.
Direction comes from WhatsApp's `data-pre-plain-text` where it exists (text from
a saved contact or a group member), from the bubble's tail marker otherwise, and
is inherited from the message above when neither is present — a tail marks only
the *first* bubble of a run, so without that last step the newest message, the
one being answered, gets dropped.

**Stickers, images and voice notes read as nothing**, and a chat with nothing
readable is skipped rather than answered — there's no text in them to reply to,
and replying anyway means answering a message the bot never read. Messages from
numbers WhatsApp can't name are covered by the tail marker.

### Draft only

Types the reply into the real chat and stops — no Enter. You see exactly what
it would have said, in context, and send it with one keystroke or delete it.
The honest way to start using any of this.

Drafts are **not** recorded as part of the conversation: a draft hasn't happened
yet and you may well bin it, so counting it would have the next reply refer back
to something that was never said. WhatsApp keeps a draft per chat, so a batch
leaves each one waiting in its own conversation, and the bubble that follows
stays on screen until you click it.

### Quiet hours

On by default, 10pm–8am. Nothing good comes of a bot that's awake when you
aren't. The window wraps past midnight; change it with `waQuietFrom` /
`waQuietTo` (hours, 0–23) in `~/.nikxel/settings.json`.

A message that lands at 2am is **held, not dropped** — it goes out once the quiet
hours end. A live meeting overrides the whole thing, on the grounds that if
you're in a meeting at 3am you're awake.

### Who it will and won't talk to

Two plain-text lists in `~/.nikxel/`, one name per line, `#` for comments. Both
are re-read on every message, so an edit takes effect immediately.

| File | Effect |
|---|---|
| `never_reply.txt` | Never answered. Beats every other setting — not during meetings, not when tagged in a group, not ever. |
| `trusted_contacts.txt` | The non-disclosure rules below are relaxed: these people get the specifics instead of "heads-down on work stuff". |

Write the name as it appears in your chat list. A first name on its own is
enough as long as it's **3+ characters** — `Asha` matches the chat *Asha Verma*.
Shorter entries must match exactly, so a stray `Jo` can't silence Joanna,
Jonathan and John at once.

Only put someone on the trusted list if they'd already be told. A co-founder,
your own team. Not a client, not a group.

### Tasks from chats

When a message contains something you actually have to **do** — "send the
pricing deck by Friday" — it's filed to **Google Tasks** (the list that shows up
in Gmail and Calendar's side panel, and in the Google Tasks app) with the
contact's name in the notes. Pure chatter files nothing.

Two things have to be in place, and Nikxel tells you which one is missing
rather than dropping tasks into a log file:

1. **The Tasks permission.** An account connected before Nikxel could write to
   Google won't have it — that grant was calendar-read-only. A dropped task
   raises a 🔑 bubble offering to reconnect; one click, nothing else changes.
2. **The Tasks API switched on** for the Google Cloud project behind your
   `google_creds.json`. Enabling Calendar does not enable Tasks: a project that
   has never used it answers `403 … has not been used in project … or it is
   disabled`. That one raises a 🔧 bubble that opens the exact console page to
   switch it on.

Either bubble appears at most once per launch, so a misconfigured account
doesn't produce one per message.

This costs no extra time: the agent is already reading the message to answer it,
so it just appends one marker line, which is stripped before the reply is sent
and never reaches the contact. It silently does nothing until you've connected a
Google account with Tasks access.

The task keeps whatever date the contact wrote, inside the title ("Send the deck
to Priya **by Friday**"), rather than being parsed into a real due date. A task
filed under the wrong Friday is worse than one with no date at all.

### What it knows

The bot reads your last **3 end-of-day summaries** before writing a reply, so a
contact asking *"any update on that thing?"* gets an answer that recognises
what they mean instead of a blank "I'll pass it on".

With **Knows What You're Working On** on (the default) it also gets a short
*right now* block: whether you're in a meeting, the app and window you're in,
today's totals (`3h 20m coding · 2 meetings`), and today's commits and
uncommitted work. Without it, the entire current day is a blind spot until the
10pm summary exists — which is the day people are most likely to ask about.

Those notes are detailed — repos and commits, window titles, meetings, who
you called and messaged. The bot answers whoever happens to write to you, so
the context is supplied under an explicit non-disclosure rule: use it to
understand the question, never to volunteer project or client names, meeting
topics, or who else you spoke to, and never admit the notes exist. If an answer
would need a detail only found there, it says you'll follow up yourself.

One exception to the non-disclosure rule: **whether you're in a meeting or free
right now is fine to share.** That's the one thing someone waiting on a reply
actually needs.

Tune the history with `botMemoryDays` in `~/.nikxel/settings.json` — `0` turns
it off, `3` is the default, `14` is the maximum. Each extra day is prepended to
every reply prompt, so it costs latency on every message. The *right now* block
is recomputed at most once every two minutes, since it shells out to git.

Nothing to set up: summaries are the ones already written to
`~/Documents/nikxel/daily/` at 10pm. With none yet, the bot falls back to the
*right now* block alone.

## Where Nikxel looks for your projects

Day summaries and the WhatsApp bot's *right now* block include what you
committed and what's still uncommitted. That comes from scanning a folder for
git repos — **`projectsRoot`** in `~/.nikxel/settings.json`, which defaults to
`~/Desktop`.

If your projects live somewhere else, set it:

```json
{ "projectsRoot": "~/Desktop/everything/projects" }
```

Worth doing even when `~/Desktop` would technically work. The scan walks every
subdirectory looking for `.git`, and a narrower root is both faster and less
likely to surface a vendored repo as if it were yours. `node_modules`, `Pods`,
`DerivedData`, `vendor`, `target`, `build`, `dist`, `.next`, `venv` and friends
are skipped outright.

Repos are found at any depth, so `projects/custom-sarvam/backend` and
`projects/nikxel/website/nikxel-site` both count.

**If the Git section is always empty**, check `~/.nikxel/chatbot.log` — the scan
says either `no git repos under <path>` or `scanned <path> — N repo(s)`. An
empty scan is usually one of two things: the root is wrong, or macOS is refusing
to let Nikxel list that folder. The second is fixed in System Settings →
Privacy & Security → Files and Folders → Nikxel.

## Note format — Markdown, PDF or Word

Menu bar → **Note Format** → Markdown (.md) · PDF (.pdf) · Word (.docx).

The Markdown your agent wrote is **always** saved; picking PDF or Word renders
that into a second file beside it, so nothing is ever lost to a failed
conversion. Both are produced by macOS itself — no pandoc, no LaTeX, nothing
to install. Headings, bullet and numbered lists, bold/italic and inline code
all carry across.

Stored as `noteFormat` in `~/.nikxel/settings.json`.

## Languages — English, Hindi, Hinglish

Set the spoken language in the wizard (**Transcription tools** → *Spoken
language*). It is stored as `transcriptionLanguage` in
`~/.nikxel/settings.json`.

**Leave it on `en`.** Despite the name, English is the best setting for all
three languages — it transcribes Hindi as Hinglish *and* keeps English words
spelled correctly. Measured on the `small` model:

| Spoken | Setting | Result |
|---|---|---|
| English | `en` | clean English |
| Hindi | `en` | `Namaste, mai kal meeting me shamil nahi ho paunga. Kripya mujhe notes bhejh deejhye.` |
| Hinglish | `en` | `Yes, I have already deployed that feature, now let's schedule the client demo tomorrow morning.` |
| English | `hi` | ❌ Devanagari gibberish |
| anything | `auto` | ❌ misreads Indian-accented English as Hindi (p = 0.68) |

So `hi` is only worth choosing for heavy, sustained Hindi where you want
maximum fidelity to the Hindi itself — and it will mangle pure English, so
switch back afterwards. Under `hi`, Nikxel transcribes in Devanagari and then
romanizes it (`Devanagari.swift`, including Hindi's word-final schwa deletion
so कल is "kal", not "kala"); English words inside that come back phonetic
("pheetchhar"), and the summary prompt tells your agent to restore them.

Either way **Hindi is never left in Devanagari** — not in the transcript, not
in the summary.

Hindi needs the `small` model or better; `base` transcribes Hindi into Urdu
script even when told `-l hi`. The wizard downloads `small` for that reason.
Dropping a `ggml-medium.bin` or `ggml-large-v3-turbo.bin` into
`~/.nikxel/models/` upgrades it — Nikxel picks the largest model present.

## Connect your Google account (optional)

One connection covers three things: a nudge from the avatar before a meeting
starts, action items pushed to **Google Tasks**, and agreed follow-ups created
as **Calendar events with a Meet link**.

1. Google Cloud Console → APIs & Services → Credentials.
2. Enable the **Google Calendar API** and the **Google Tasks API**.
3. Create OAuth client ID → "Desktop app". Download the JSON.
4. Save it to `~/.nikxel/google_creds.json`.
5. Status bar → **Connect Google Account…** to run the OAuth flow.

See the in-app prompt for the full step-by-step.

### Sending a meeting's tasks to Google

When a meeting summary finishes, Nikxel reads its own **Action Items** and
**Follow-Up Meetings** sections and shows you the list:

> **Send this meeting's tasks to Google?**
> • Rewrite the retry logic before the demo (due 12 Nov)
> • [Rohan] Send Priya the updated pricing sheet (due 12 Nov)
> • Chase legal on the DPA (due 20 Nov)
> 📅 Design review — 12 Nov, 15:30, 45 min

Nothing is sent until you press **Add to Google**. A few details worth knowing:

- Tasks owned by somebody else are prefixed with their name (`[Rohan] …`) —
  Google Tasks has no assignee field, so this is the only way a glance at the
  list tells you whose it is. Your own and unassigned tasks get no prefix.
- Only due dates the meeting actually gave become due dates. *"by next Friday"*
  with no date attached arrives as a task with no deadline rather than a
  guessed one.
- Follow-ups become events only when a real date **and** time were agreed.
- Attendees aren't invited — a transcript has names, not email addresses, and
  guessing one would invite a stranger to your meeting. The names go in the
  event description for you to invite from.
- Each summary is pushed at most once, tracked in `~/.nikxel/synced/`, so
  regenerating a note can't duplicate your todo list.

Turn the whole thing off with **Send Meeting Tasks to Google: Off** in the menu
bar, or `"googleSyncEnabled": false` in `~/.nikxel/settings.json`.

If you connected Google before this existed, your grant is still read-only —
Nikxel will say so and offer to reconnect the first time a summary has
something to send.

## Customizing

### Change your avatar
Menu bar → **Setup Wizard…** → **Your avatar**. See
[Make your own avatar](#make-your-own-avatar).

### Change what your summaries contain
Menu bar → **Summary Template** — Developer, Project Manager, HR, Co-founder,
or one you write yourself. See [summary templates](#summary-templates).

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
- **Notification bubbles**: a CoreGraphics speech card drawn straight into the avatar's window (`NikxelCard.swift`), one at a time, newest replacing the last; the window is 340x520 so there is headroom above the sprite, and it grew upward only so updating doesn't move Nikxel on screen
- **Summary templates**: plain-text instruction files in `~/.nikxel/templates/`, injected into the prompt as `{{custom_instructions}}` — an overlay on the shipped prompt rather than a copy of it, so templates don't go stale when the prompt improves
- **Google sync**: one OAuth grant (`GoogleAuth`) shared by the calendar poll and the task/event writer; the writer parses the Markdown the agent already wrote rather than making a second LLM call, which is why **Action Items** and **Follow-Up Meetings** have a fixed line format
- **Calendar / reminders**: Google Calendar v3 REST API on a 30 s poll; EventKit for Apple Reminders with `EKEventStoreChanged` notifications + `NSWorkspace.didWake` for wake-from-sleep refresh
- **Daily summary**: 15 s `NSWorkspace.frontmostApplication` + AX `kAXFocusedWindowAttribute`/`kAXTitleAttribute` polling → JSONL day-log; aggregated at 10 pm with `git log`/`git diff`, today's MOMs, Claude Code JSONL session transcripts, and `sqlite3` queries against the opencode database; narrative written by your chosen coding agent

## Where files live

| What | Where |
|---|---|
| Notes (YouTube / lectures / podcasts) | `~/Documents/nikxel/notes/` (`.md`, plus `.pdf`/`.docx` if chosen) |
| Meeting MOM (per-speaker) | `~/Documents/nikxel/meetings/` |
| Daily summaries | `~/Documents/nikxel/daily/` |
| Raw day-activity log (JSONL) | `~/Library/Application Support/Nikxel/days/` |
| Prompt templates | `~/.nikxel/prompts/notes.md` & `meeting.md` |
| Summary templates (one file each) | `~/.nikxel/templates/*.txt` |
| Speech models (whisper.cpp) | `~/.nikxel/models/` |
| Raw recordings (kept until processed) | `~/.nikxel/recordings/` |
| MOM workspace / last-run logs | `~/.nikxel/momworkspace/` |
| Google OAuth creds & token | `~/.nikxel/google_creds.json`, `~/.nikxel/google_token.json` |
| Your custom avatar (if you made one) | `~/.nikxel/sprites.png` |
| Already-pushed-to-Google markers | `~/.nikxel/synced/` |
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
