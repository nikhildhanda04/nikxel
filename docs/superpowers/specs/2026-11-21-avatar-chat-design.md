# Avatar chat: click Nikxel, ask anything about your work

## Why
Nikxel already holds a lot of useful history:
- your daily summaries;
- your meeting minutes and notes;
- through the dashboard, the minutes teammates share to your projects.

Getting an answer out of that history today means opening files. The user wants to click the avatar and ask, typed or spoken, for example:
- "what was discussed in my last PS meeting?"
- "what's the update on this task?"

The answer should come back in about 10 seconds.

This comes before the pre-meeting brief, which is the next feature. The brief will reuse the same project-context fetch and the same agent call.

## Goals
- **Open with a single click.** Clicking the avatar without moving it opens a small translucent chat box beside it. Clicking it again closes the box.
- **Type or speak.** Type and press Enter, or click the mic, speak, and click it again. The speech is transcribed locally and sent as the question.
- **Fast answers.**
  - The question is answered by the user's connected coding agent, using the context Nikxel gathers.
  - The target is about 10 seconds.
  - A visible "thinking…" state shows while it works.
- **Knows your history:**
  - local daily summaries, meeting minutes and notes;
  - recent shared minutes and work on the user's dashboard projects.
- **Follow-ups work.** The exchanges so far in the open box are sent with each new question.
- **Mac and Windows**, in the same commit.

## Non-goals and anti-goals
- **No saved chat history.** Closing the box forgets the conversation.
- **The chat can't act.** It doesn't edit summaries, send messages or create tasks. It only answers.
- **No server-side AI.** The server only serves data the user can already read.
- **No meeting transcripts, audio or raw activity logs in the context.** Only the summarised `.md` files are used.
- **Anti-goal: a chat that is slow or in the way.** Avoid:
  - a box that steals focus from the user's work;
  - a click that misfires while dragging or double-clicking;
  - answers that take a minute.

## Approaches considered
- **A (chosen): gather first, one quick agent call.** The app builds the context itself (recent local files plus the project feed) and makes a single prompt to a fast model, `haiku` for Claude, via `MOMGenerator.runPrompt`, which already falls back to other installed agents. This is the only way to hit about 10 seconds.
- **B: the agent searches files itself.** It's more thorough and can go further back, but takes 30–60 seconds. Rejected because it's too slow for a quick box.

Gestures considered:
- **Single click (chosen).**
- Triple-click: rejected by the user.
- Right-click: harder to discover.
- A keyboard shortcut: a possible later extra.

## Decided
- **Gesture:**
  - A mouse-down on the avatar followed by a mouse-up with less than 4 pt of movement counts as a click.
  - The chat opens 0.25 s after that, unless a second click arrives first. A second click means double-click, which keeps its current recording toggle.
  - A drag is unchanged.
  - Clicks on reminder bubbles and the day card keep their current priority.
- **Box:**
  - About 320 × 280 pt, translucent (vibrancy on Mac, a frameless transparent window on Windows), placed beside the avatar on the side with room.
  - Contents: a message list, newest at the bottom; a text field; a mic button; a send button.
  - Esc, or clicking the avatar again, closes the box.
  - Clicking elsewhere leaves the box open, so the user can read while working.
  - It takes key focus only when it opens.
- **Voice:**
  - The mic button toggles recording.
  - On stop, the audio is transcribed locally with the existing `Transcriber` (Whisper).
  - The text goes into the field and is sent automatically.
  - If the transcription is empty, the box says "Didn't catch that."
- **Context, newest first:**
  - **Local:** `~/Documents/nikxel/{daily,meetings,notes}/*.md` from the last 14 days, by the date in the filename. `*.transcript.txt` is excluded.
  - **Cloud:** the project feed for the user's projects (below), last 14 days.
  - **Cap:** about 250,000 characters in total. The oldest files are dropped first, and every file is labelled with its kind, date and path or project.
  - **Today's date** is included so "last meeting" and "yesterday" resolve correctly.
- **New endpoint:** `GET /api/device/projects/feed?days=14`, with device auth.
  - It returns `[{id, name, days:[{date, meetings:[{title, body, name}], items:[{text, section, name}]}]}]`.
  - It covers the paired user's non-archived projects they are a member of, using the same day building as `GET /api/projects/:id`.
  - `days` is clamped to 1–60.
  - The app caches the last good response to `~/.nikxel/project-feed.json` and uses it when offline.
  - The pre-meeting brief will reuse it.
- **Prompt:**
  - Answer only from the context.
  - Say plainly when the answer isn't there.
  - Short answers: a few lines or bullets.
  - Name the meeting or person and date an answer came from.
  - The question, plus earlier exchanges in this box, go at the end.
  - Run kind: `"chat"`.
- **Failures:**
  - **No agent installed:** "Connect Claude in Settings to use chat."
  - **Agent error or timeout (30 s):** the error is shown in the box and the question stays in the field.
  - **Dashboard unreachable with no cache:** the answer uses local context only, and the box shows a small note "projects offline".
- **Platforms:**
  - **Mac:** `NikxelWindowController.mouseDown/mouseUp`, plus a new `src/AvatarChat.swift` (panel, context building, agent call).
  - **Windows:** the `avatar.ts` click path, plus `windows/src/main/system/avatarChat.ts` and a small renderer window.
  - Voice on Windows uses the existing renderer recorder and `transcriber.ts`.

## Calls made after the builder check
- **Mic during a recording:** while a meeting or note recording is running, the chat mic button is disabled ("Recording — type instead"), so there's never a second capture. Voice reuses the recorder-to-`Transcriber` path the summary-page mic uses, writing to its own file.
- **Clicks while the box is open:** the same 0.25 s rule applies.
  - A lone click closes the box.
  - A double-click toggles recording as it does today and leaves the box as it is.
- **Speed beats size:**
  - The first plan task times one `haiku` call with about 80k and about 250k characters of real context.
  - The cap is set to the largest that answers in under about 10 s.
  - If even 80k is too slow, older daily summaries are trimmed before meetings and notes.
- **Feed contents:** the same items as the project page, meaning items members Sent tagged to the project plus shared minutes. There's no further per-user filtering. Factor the day-building out of `GET /api/projects/:id` into a shared function.
- **Agents:**
  - `claudeModel: "haiku"` for Claude; other agents use their defaults.
  - The timeout is passed to the agent run: 30 s, not the minutes timeout.
  - Windows passes the same `kind: "chat"`.
- **Windows window:** a separate frameless, transparent, always-on-top window, positioned beside the avatar window.
- **Dates in filenames:** dailies are `YYYY-MM-DD.md`; meetings and notes are `YYYY-MM-DD-HHMM[SS].md`. Take the first 10 characters and skip files that don't parse.

## Left to the builder
- The exact visual styling, within "small, translucent, matches Nikxel's look".
- How the box follows the avatar if it's dragged while the box is open. Closing it on drag is acceptable.
- The exact prompt wording.
- Splitting context building into a testable pure function. A check for the 14-day filter, the cap and the order is expected.
