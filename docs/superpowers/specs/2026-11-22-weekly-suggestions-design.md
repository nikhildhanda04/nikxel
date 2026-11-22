# Design: Weekly suggestions — advice, and tasks Nikxel offers to take on

## Intent and why

Nikxel already watches how each person works (apps and window titles every 15s, meetings, calendar, WhatsApp, Slack, ERP, coding sessions, summary edits) but turns almost none of it back into help. Today it can suggest exactly three things (a later summary time, auto-recording calls, a standing summary rule), the same three for everyone.

The user (Nikxel's maker) wants Nikxel to suggest **custom workflows per person** — things that make that person's work easier — in two forms:

1. **Advice** the person acts on themselves ("you switch between Slack and Xcode ~40×/hour before noon — try batching Slack at 12 and 4").
2. **Offers** to take a task on: "I'm thinking of … Will this suit you better?" — a yes makes Nikxel do it from then on.

## Goals

- Suggestions specific to the person, grounded in their own week, citing the evidence ("on 4 of 5 days…").
- Offers only for things Nikxel can actually do; a yes applies it immediately, a no is never asked again.
- Works the same on macOS (`src/`) and Windows (`windows/`).
- The catalogue of doable tasks grows as Nikxel gains skills, without redesign.

## Non-goals (phase 1)

- Nikxel inventing or running new automations not in the catalogue (approach C, rejected).
- New capabilities built only to be offered (posting to Slack, pre-meeting briefs). They join the catalogue when they exist.
- Suggestions on the team dashboard.

## Anti-goals (a failure even if it works)

- Nagging: more than one question a day, or re-asking something declined.
- Generic advice ("take breaks", "use a to-do list") that ignores the person's data.
- An offer whose yes does nothing, or does something other than what the question said.
- Raw activity (window titles, message text) leaving the machine beyond the AI call Nikxel already makes for summaries.

## Constraints

- Uses the same AI path as summaries (`MOMGenerator.runPrompt` / its Windows twin); one extra call a week per person.
- Reuses `Learning.offer` for asking: at most one question a day across all learning, answers stored in `~/.nikxel/learning.json`.
- Pure logic (digest building, reply parsing/validation) lives beside `Habits.swift` / `habits.ts` and gets a check in `check_habits.swift` / `habits.test.ts`.
- Must not touch the other session's uncommitted files: `src/DayPage.swift`, `src/PageEdit.swift`, `src/PageShare.swift`, `windows/src/main/system/dayPage.ts`.

## Approaches

- **A. Fixed list of hand-written habit checks.** Predictable and testable, but the same for everyone and every new idea is a release. Rejected: not personal enough.
- **B. Weekly AI review over a digest, limited to a catalogue of actions. — Chosen.** Code builds a compact digest of the week; the AI proposes advice and offers; code throws out any offer not in the catalogue. Personal, and offers stay safe.
- **C. AI writes and runs new automations.** Most powerful, but Nikxel acting on WhatsApp/Slack/ERP in untested ways. Rejected for now.

## The design (decided)

### When
Right after the week in review is written (Sunday 9am, or its Monday/Tuesday backfill, in `DayLogger.generateWeek`). One AI call, at most once per week: the week's key is stored in `learning.json`, so a manual "write my week now" doesn't re-run it or re-queue offers.

### The digest (code, pure)
Built from data Nikxel already keeps, last 7 days, a few hundred lines at most:
- Time per app and per top window titles; first and last activity each day.
- App switches per hour, by time of day; the most frequent back-and-forth app pairs.
- Meetings: count, typical times, recurring titles; what the person usually opens or does in the 30 minutes after one (from the activity log). A meeting's end is the saved minutes file's time, falling back to the calendar event's end.
- Summary fixes from `edits/instructions.jsonl`.
- WhatsApp reply times, from the existing chat-list log (`whatsapp/chats` JSONL: every ~2 min, each chat's last-message preview, the user's own prefixed `You:`). Per chat, an incoming preview followed by the first later `You:` preview is one reply; its wait is the gap (accurate to ~2 min; replies sent from the phone count too). Digest: median wait by hour of day and by chat (1:1 vs group), the chats waited on longest, and incoming messages never answered that day. No new capture and no chat is opened (opening one marks it read on the phone).
- ERP tasks logged (titles, days).
- Window and ERP titles capped at 90 characters, as the daily summary already does; no message text.
- Current settings relevant to the catalogue, and the keys already answered in `learning.json` (so declined ideas aren't repeated).

### The catalogue (code)
Each entry: an id, what its parameters are, how to describe it, how to apply it. Phase 1 holds only what exists today:
- `summaryTime(minutes)` — `NikxelSettings.summaryMinutes`
- `autoRecordCalls` — `NikxelSettings.autoRecordCalls = true`
- `summaryRule(text)` — append to the active summary template (as `offerRule` does)
- `waQuietHours(from, to)` — `waQuietHours`, `waQuietFrom`, `waQuietTo`
- `waDraftOnly` — `NikxelSettings.waDraftOnly = true`
- `waChatTasks` — `NikxelSettings.waChatTasks = true`
- `summaryTemplate(name)` — switch to an existing template

### The AI step
Prompt = digest + catalogue (ids, parameters, one-line meaning) + the person's role/context block. Reply: JSON with up to 3 items, each either
`{"kind":"advice","text":…,"evidence":…}` or `{"kind":"offer","action":<catalogue id>,"params":{…},"line":"I'm thinking of …","evidence":…}`.
Code validates: unknown action, bad parameters, an offer that would change nothing (compared on the actual values — e.g. `waQuietHours` defaults on, so its from/to are compared), or an already-answered key → dropped. `summaryRule` offers use the existing `rule:<text>` key so the daily rule check and the weekly review never ask the same idea twice. Nothing valid → nothing shown.

### Showing it
- **Advice** is appended to that week's review as a `## Ideas for you` section before the page is rendered (the markdown is extended, so the renderer is untouched).
- **Offers** are queued in `learning.json` and asked one per day via `Learning.offer`, starting the day after, in the existing "💡 … Will this suit you better?" bubble with the evidence in the line. A yes runs the catalogue entry's apply; a no is stored under a key derived from action + params.
- Queued offers are a fourth check in `Learning.daily` (after the existing three), so they're asked from the same after-summary hook; a day with no summary asks nothing. Queued offers take a day's slot only when none of the existing three asks.

## Calls made during review (correct me)

- WhatsApp reply times are read from the existing chat-list log (~2-min accuracy) rather than adding capture.
- Titles go to the AI capped at 90 chars, same as daily summaries.
- Meeting end = minutes file time, else calendar end.
- Once per week, guarded by week key; manual regenerate doesn't repeat it.
- Offers ride the existing daily after-summary hook.

## Left to the builder

- Exact digest format and the caps that keep it small.
- How the "what happens after a meeting" pattern is read from the activity log.
- The prompt wording, within the shape above.
- Queue expiry (suggest: an unasked offer older than 14 days is dropped).
