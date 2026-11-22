# Weekly Suggestions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Once a week, Nikxel reads a digest of the person's week and gives them personal advice (in the week in review) plus offers to take tasks on (asked one a day, applied on a yes).

**Architecture:** Pure logic (reply times, activity stats, digest, catalogue, prompt, reply validation) lives in a new `src/Suggestions.swift`, mirrored in `windows/src/main/system/suggestions.ts`, each with a runnable check. `Learning` gains a weekly entry point (gather inputs → one AI call → ideas markdown + queued offers) and a fourth daily check that asks queued offers. `DayLogger.generateWeek` calls the weekly entry point and appends its ideas to the week's markdown before rendering. A small bot-sent log keeps Nikxel's own WhatsApp replies out of the reply times.

**Tech Stack:** Swift (macOS app, `./build.sh`), TypeScript/Electron (`windows/`, `npm run check`).

**Spec:** `docs/superpowers/specs/2026-11-22-weekly-suggestions-design.md`

## Global Constraints

- Every `src/` change has its `windows/` twin in the same commit; Swift and TS behave the same and their checks assert the same cases.
- Never edit, stage or commit `src/DayPage.swift`, `src/PageEdit.swift`, `src/PageShare.swift`, `windows/src/main/system/dayPage.ts` (another session's uncommitted work). Stage files by name, never `git add -A`.
- At most one question a day across all learning (`Learning.offer`'s `askedDay`); a declined key is never asked again.
- One AI call per week per person, guarded by the week's key; `generateWeekNow` must not repeat it.
- No new WhatsApp capture beyond the bot-sent log; never open a chat to measure anything.
- Window and ERP titles in the digest are capped at 90 characters; no message text in the digest.
- `Suggestions.swift` / `suggestions.ts` stay pure: Foundation (TS: nothing app-specific) only, no reads of settings, files or the clock beyond their arguments — the Swift check compiles that file alone.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Swift check: `swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/csg src/Suggestions.swift check_suggestions.swift && /tmp/csg`. Windows check: `cd windows && npm run check`.

## Review Focus

- Nikxel's own bot replies counted as the user's replies → reply times look instant. Expect: replies whose preview matches a bot-sent message for that chat within 5 minutes are ignored (Task 1, Task 2 tests).
- Chat-log days with only "You:" previews, or a chat whose first preview is the user's own → no reply recorded, no crash (Task 2).
- The AI returns prose, fenced JSON, more than 3 items, an unknown action, or out-of-range params → only valid items survive, at most 3 (Task 4 tests).
- An offer that changes nothing (quiet hours already 22→8, template already active, auto-record already on) is dropped (Task 4 tests).
- Manual "write my week now" twice in a week → second run makes no AI call and queues nothing (Task 5).

---

### Task 1: Log what Nikxel's WhatsApp bot sends

**Files:**
- Modify: `src/WhatsAppActivityLogger.swift` (add `logBotSent`), `src/ChatbotEngine.swift:600-606` and `:711-716` (call it after a successful real send)
- Modify: `windows/src/main/whatsapp/whatsAppActivityLogger.ts` (same; widen `readLog`'s `file` type to `"chats" | "calls" | "bot"`), `windows/src/main/whatsapp/chatbotEngine.ts:493` and `:601`

**Interfaces:**
- Produces: `WhatsAppActivityLogger.logBotSent(chat: String, text: String)` (static) writing `{"t", "name", "text"}` (text cut to 120 chars) to the day file `bot` through the existing `appendJSONL(file:entry:)` / daily-file path; read back with `WhatsAppActivityLogger.readLog(file: "bot", for:)`. TS: `WhatsAppActivityLogger.logBotSent(chat, text)`, same file and shape.

- [ ] **Step 1:** Add `logBotSent` beside `appendJSONL` in both loggers (static; appendJSONL is an instance method on `shared`, so go through `shared` and its queue).
- [ ] **Step 2:** At both send sites in both ChatbotEngines, call it only when the send succeeded and it was a real send (not draft mode), with the chat's name (`chat.name` / `m.contact`) and the text.
- [ ] **Step 3:** Run `./build.sh` → builds. Run `cd windows && npm run typecheck` → passes.
- [ ] **Step 4: Commit** `feat: log what Nikxel's WhatsApp bot sends, so it isn't mistaken for the user's replies` (stage the four files by name).

### Task 2: Reply times from the chat-list log

**Files:**
- Create: `src/Suggestions.swift`, `check_suggestions.swift`
- Create: `windows/src/main/system/suggestions.ts`, `windows/src/checks/suggestions.test.ts`

**Interfaces:**
- Produces (Swift, inside `enum Suggestions`):
  - `struct Reply: Equatable { let chat: String; let group: Bool; let incomingAt: TimeInterval; let repliedAt: TimeInterval? }`
  - `static func replies(chats: [[String: Any]], bot: [[String: Any]]) -> [Reply]`
- TS: `export interface Reply { chat: string; group: boolean; incomingAt: number; repliedAt: number | null }`, `export function replies(chats: any[], bot: any[]): Reply[]`.

Rules: entries (`t`, `name`, `preview`) grouped by `name`, sorted by `t`. A preview starting `You: ` is own; anything else is incoming. The first incoming after the last own (or the start) opens a wait; the next own preview closes it (`repliedAt = t`). An own preview is ignored (does not close the wait) when a bot entry for the same `name` has `|t_bot − t| ≤ 300` and the preview text after `You: ` starts with the bot text's first 40 characters (or vice versa when the preview is shorter). Waits still open at the end are returned with `repliedAt = nil`. `group` is true when any incoming preview of that chat has the form `<sender>: <text>` with a sender of 1–40 characters and no `:` (ponytail: heuristic; a 1:1 message that itself starts "Word: …" reads as a group).

- [ ] **Step 1: Write the failing checks** (same cases in both files):
  - incoming at 100, own at 400 → `[Reply(chat:"Asha", group:false, incomingAt:100, repliedAt:400)]`
  - incoming 100, incoming 220 (new preview), own 400 → one reply, `incomingAt` 100
  - own first, then incoming 500, nothing after → one reply with `repliedAt` nil
  - incoming 100, own 250 matching bot `{t:240,name:"Asha",text:"Sure, I'll check"}` with preview `You: Sure, I'll check`, own 900 → one reply `repliedAt` 900
  - group chat `Ben: lunch?` at 100, `You: yes` at 160 → `group` true, replied 160
  - empty input → `[]`
- [ ] **Step 2:** Run the Swift check and `npm run check` → FAIL (missing `replies`).
- [ ] **Step 3:** Implement `replies` in both files.
- [ ] **Step 4:** Run both checks → PASS.
- [ ] **Step 5: Commit** `feat: reply times from WhatsApp's chat list, without the bot's own replies`.

### Task 3: Activity patterns — switching, app pairs, after meetings

**Files:** Modify `src/Suggestions.swift`, `check_suggestions.swift`, `windows/src/main/system/suggestions.ts`, `windows/src/checks/suggestions.test.ts`.

**Interfaces:**
- Produces (Swift):
  - `struct Sample { let t: TimeInterval; let app: String; let title: String }`
  - `struct Meeting { let start: TimeInterval; let end: TimeInterval; let title: String }`
  - `static func switchesByHour(_ s: [Sample], calendar: Calendar = .current) -> [Int: Double]` — hour of day → average app changes per active hour (an hour counts as active when it has ≥ 1 sample; consecutive samples with the same app are not a switch; `loginwindow`, `ScreenSaverEngine` (TS: `LockApp`) samples are dropped first).
  - `static func topPairs(_ s: [Sample], limit: Int = 5) -> [(a: String, b: String, count: Int)]` — unordered app pairs by number of direct switches between them, most first, ties by name.
  - `static func afterMeetings(_ m: [Meeting], _ s: [Sample]) -> [(app: String, meetings: Int)]` — for each meeting, the distinct apps in samples within `end ..< end + 1800`; counted across meetings, only apps seen after ≥ 2 meetings, most first.
- TS: same names, camelCase, objects `{ a, b, count }` / `{ app, meetings }`, `switchesByHour(s, ...)` returns `Record<number, number>`.

- [ ] **Step 1: Write the failing checks** (both files): samples Code→Slack→Code→Slack in hour 10 and Code only in hour 11 → `switchesByHour == [10: 3, 11: 0]`; `topPairs` on the same → first `(Code, Slack, 3)`; two meetings each followed within 30 min by `Odoo` and one by `Mail` → `afterMeetings == [("Odoo", 2)]`.
- [ ] **Step 2:** Run both → FAIL.
- [ ] **Step 3:** Implement in both.
- [ ] **Step 4:** Run both → PASS.
- [ ] **Step 5: Commit** `feat: weekly activity patterns for suggestions`.

### Task 4: Digest, catalogue, prompt, and validating the AI's reply

**Files:** Modify `src/Suggestions.swift`, `check_suggestions.swift`, `windows/src/main/system/suggestions.ts`, `windows/src/checks/suggestions.test.ts`.

**Interfaces:**
- Produces (Swift):
  - `struct Settings { var summaryMinutes: Int; var autoRecordCalls: Bool; var waDraftOnly: Bool; var waQuietHours: Bool; var waQuietFrom: Int; var waQuietTo: Int; var waChatTasks: Bool; var summaryTemplate: String; var templates: [String] }`
  - `struct Input { var samples: [Sample]; var meetings: [Meeting]; var chats: [[String: Any]]; var bot: [[String: Any]]; var edits: [String]; var erp: [(day: String, name: String, project: String)]; var settings: Settings; var declined: [String] }`
  - `static func digest(_ i: Input, calendar: Calendar = .current) -> String`
  - `static func prompt(digest: String, context: String) -> String`
  - `enum Item: Equatable { case advice(text: String, evidence: String); case offer(action: String, params: [String: String], line: String, evidence: String) }`
  - `static func parse(_ reply: String, settings: Settings, answered: Set<String>) -> [Item]`
  - `static func key(action: String, params: [String: String]) -> String` — `"rule:" + params["text"]` for `summaryRule`; otherwise `"weekly:" + action + ":" + params sorted by key as k=v joined by ","`.
- TS: same names; `Item` is `{ kind: "advice", text, evidence } | { kind: "offer", action, params: Record<string,string>, line, evidence }`.

**Digest** — plain text sections, each capped (left to the builder: exact layout), containing: hours per app (top 10) and per window title (top 10, titles cut to 90 chars); first/last activity per day; `switchesByHour`; `topPairs`; meeting count, start hours, recurring titles (seen ≥ 2×), `afterMeetings`; from `replies`: median wait in minutes by hour of day, median for 1:1 vs group, the 5 chats with the longest median wait, unanswered count per day; summary fixes (last 20, each ≤ 120 chars); ERP tasks (day, name ≤ 90, project); the current `Settings`; `declined` ideas. No chat names beyond the top-5 list, no message text.

**Catalogue** (ids, params, valid when, no-op when):
| id | params | valid | no-op (dropped) |
|---|---|---|---|
| `summaryTime` | `minutes` | int 1080…1740 | equals `summaryMinutes` |
| `autoRecordCalls` | — | — | `autoRecordCalls` already true |
| `summaryRule` | `text` | 1…120 chars | — |
| `waQuietHours` | `from`, `to` | ints 0…23, from ≠ to | `waQuietHours` true and same from/to |
| `waDraftOnly` | — | — | already true |
| `waChatTasks` | — | — | already true |
| `summaryTemplate` | `name` | in `templates` | equals `summaryTemplate` |

**Prompt** — includes the digest, the catalogue (id, params, one-line meaning), `context` (the role/user-context block), and asks for one line of JSON: `{"items":[…]}` with at most 3 items of the two shapes in the spec; advice must cite the person's own numbers in `evidence`; offers' `line` must start "I'm thinking of".

**parse** — take the text between the first `{` and last `}`; read `items`; keep advice with non-empty `text`; keep offers whose action is in the catalogue, params valid, not a no-op, `key` not in `answered`, `line` non-empty; at most 3 in reply order; anything unreadable → `[]`. Params arrive as JSON strings or numbers; store as strings.

- [ ] **Step 1: Write the failing checks** (both files):
  - reply wrapped in prose and a code fence with 1 advice + 1 valid `summaryTime` offer (`minutes:1560`, current 1320) → both kept
  - `{"items":[{"kind":"offer","action":"postToSlack",…}]}` → `[]`
  - `waQuietHours` `{from:22,to:8}` with settings quiet on 22→8 → dropped; `{from:21,to:8}` → kept
  - `summaryTemplate` name not in `templates` → dropped
  - `autoRecordCalls` when already on → dropped
  - `summaryRule` whose `rule:<text>` key is in `answered` → dropped
  - 5 valid advice items → 3 kept
  - `"NONE"` → `[]`
  - `key(action:"waQuietHours", params:["to":"8","from":"21"]) == "weekly:waQuietHours:from=21,to=8"`
  - `digest` of an input with one 200-char window title contains no line longer than the 90-char cut of that title and contains `"Code"`
- [ ] **Step 2:** Run both → FAIL.
- [ ] **Step 3:** Implement in both.
- [ ] **Step 4:** Run both → PASS.
- [ ] **Step 5: Commit** `feat: suggestion digest, catalogue and reply validation`.

### Task 5: Wire it in — weekly run, ideas section, daily offers

**Files:**
- Modify: `src/Learning.swift`, `src/DayLogger.swift` (in `generateWeek` and a samples-with-titles reader), `build.sh` only if `src/*.swift` doesn't already pick up the new file (it does: `src/*.swift`)
- Modify: `windows/src/main/system/learning.ts`, `windows/src/main/system/dayLogger.ts`

**Interfaces:**
- Consumes: everything in `Suggestions` / `suggestions.ts`; `WhatsAppActivityLogger.readLog(file:for:)` for `chats` and `bot`; `ERP.tasksTouched(on:)` (TS: `tasksTouched(day)`, async); meetings from `~/Documents/nikxel/meetings/<yyyy-MM-dd-HHmm[ss]>.md` (start from the name, end from the file's modification time, title from its first `# ` line); edits via `Learning`'s private `edits(since:)`; `SummaryTemplates.available()`; `MOMGenerator.runPrompt(_:kind:)` with `kind: "weekly-suggestions"`.
- Produces:
  - `DayLogger.weekSamples(end: Date) -> [Suggestions.Sample]` — the 7 days before `end`, from the same day files `recentSamples` reads, keeping `title`.
  - `Learning.weekly(dayLogger: DayLogger, agent: MOMGenerator, weekKey: String) -> String` — returns the `## Ideas for you` markdown (empty string when nothing, or when `weekKey` equals `learning.json`'s `suggestedWeek`); sets `suggestedWeek = weekKey` before the AI call; stores offers in `learning.json` `queued: [{action, params, line, evidence, at}]`, replacing any older queue. TS: `async weekly(dayLogger, agent, weekKey): Promise<string>`.
  - `Learning.daily` runs a fourth check, `offerQueued()`, only when the first three asked nothing: drops queued items older than 14 days or whose key is answered, re-checks no-op against current settings, and asks the first via `offer(key:title:line:apply:)` with `title: "An idea for your week"` and the line `"<line> (<evidence>)"`; removes it from the queue when asked.
  - Apply per action: `summaryTime` → `NikxelSettings.summaryMinutes = m` then `dayLogger.reschedule()` on main (as `offerSummaryTime` does); `autoRecordCalls`/`waDraftOnly`/`waChatTasks` → set true; `waQuietHours` → set `waQuietHours = true`, `waQuietFrom`, `waQuietTo`; `summaryTemplate` → `NikxelSettings.summaryTemplate = name`; `summaryRule` → same append as `offerRule` (extract that append into a shared private helper and use it from both).
  - `daily` gains the agent it already receives; `offerQueued` needs `dayLogger` for the reschedule.

- [ ] **Step 1:** Add `weekSamples` to both DayLoggers.
- [ ] **Step 2:** Add `weekly`, the queue, `offerQueued`, the apply switch and the shared rule-append helper to both Learning modules. `weekly` builds `Suggestions.Input` from the sources above, runs `prompt` → `runPrompt` → `parse(answered:)` (answered = keys of `learning.json` `answered`), returns advice as `## Ideas for you` followed by `- <text> — <evidence>` lines, and queues the offers. Any thrown error → log with `cblog` and return `""`.
- [ ] **Step 3:** In both `generateWeek`s, after `output` is produced and before the markdown and page are written, append `Learning.weekly(dayLogger: self, agent: momGenerator, weekKey: dayKey(end))` (with a blank line) when non-empty. Week pages are rendered from that markdown, so the renderer is untouched.
- [ ] **Step 4:** Run `./build.sh` → builds; Swift check → PASS; `cd windows && npm run check` → PASS.
- [ ] **Step 5: Manual check (Mac):** with at least a few days of logs, trigger "write my week now"; the week page shows `## Ideas for you` (or none if the AI found nothing), `~/.nikxel/learning.json` has `suggestedWeek` and `queued`; trigger it again → `cblog` shows no second `weekly-suggestions` run. Set `askedDay` to yesterday and call `Learning.daily` (or wait for the day summary) → the bubble asks the first queued offer; "Yes" changes the setting.
- [ ] **Step 6: Commit** `feat: weekly suggestions — ideas in the week in review, offers asked one a day` (stage the four files by name; not `DayPage`/`PageEdit`/`PageShare`/`dayPage.ts`).
