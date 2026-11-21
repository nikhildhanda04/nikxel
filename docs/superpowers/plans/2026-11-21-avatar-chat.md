# Avatar Chat Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Single-click the avatar to open a small translucent chat box. Type or speak a question, and the connected coding agent answers in about 10 s from your recent summaries, minutes and project feeds.

**Architecture:**
1. A new device-auth endpoint serves the paired user's project feeds.
2. A pure context builder on each platform gathers local `.md` files from the last 14 days plus that feed, newest first and capped.
3. A chat window modelled on the existing Edit chat (`EditChat` in `git show HEAD:src/PageEdit.swift`; `windows/src/main/system/pageEdit.ts` + `renderer/editChat.*`) sends `context + history + question` through `MOMGenerator.runPrompt(kind: "chat", claudeModel: "haiku", timeout: 30)`.
4. A single click on the avatar (0.25 s after mouse-up, cancelled by a second click) toggles the window.

**Tech Stack:**
- Express + better-sqlite3 (`cloud/server`, `node --test`);
- Swift/AppKit + WKWebView (`src/`, built by `build.sh`, which compiles `src/*.swift`, with runnable `check_*.swift` scripts);
- Electron + TypeScript (`windows/`, `npm run check`).

**Spec:** `docs/superpowers/specs/2026-11-21-avatar-chat-design.md`

## Global Constraints

- **Mirror rule:** every `src/` change is mirrored in `windows/` in the same commit.
- **Other session's files.** Never edit, stage, stash or reset `src/DayPage.swift`, `src/PageEdit.swift`, `src/PageShare.swift` or `windows/src/main/system/dayPage.ts`. They hold another session's uncommitted work. Copy the EditChat pattern into new files; don't refactor it out. Stage files by explicit path, never `git add -A`/`.`.
- Never commit `cloud/dashboard/vite.local3011.config.js`.
- Commit trailer: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Context sources:**
  - `~/Documents/nikxel/{daily,meetings,notes}/*.md`, dated by the first 10 characters of the filename (`YYYY-MM-DD`). Files that don't parse are skipped.
  - `*.transcript.txt` and anything not ending `.md` are never read.
  - Last 14 days, inclusive of today.
- **Cap:** `CHAT_CONTEXT_CAP` characters (initial value 80_000, tuned in Task 2).
  - Blocks are added newest first.
  - When over the cap, daily summaries older than 2 days are dropped before meetings and notes.
  - Then the oldest of anything is dropped until it fits.
- **Block label:** each block starts with `### <kind> · <YYYY-MM-DD> · <name>`, where kind is `daily`, `meeting`, `note` or `project`, and the name is the filename stem or the project name.
- **Agent call:** `runPrompt(prompt, kind: "chat", claudeModel: "haiku", timeout: 30)`. Other agents use their defaults.
- **Box:**
  - About 320×280 pt, translucent, floating, beside the avatar on the side with room.
  - Esc closes it. Clicking the avatar again closes it. Clicking elsewhere does not. History is forgotten on close.
- **Copy strings (exact):**
  - `"Connect Claude in Settings to use chat."` when no agent is found;
  - `"Didn't catch that."` for an empty transcription;
  - `"Recording — type instead"` as the mic tooltip while a recording runs (the mic is disabled);
  - `"projects offline"` as a small note when the feed and its cache are both unavailable;
  - `"thinking…"` while waiting.

## Review Focus

- **Drag versus click:** a press that moves 4 pt or more is a drag and never opens the chat. A press-and-release under 4 pt with no second click within 0.25 s toggles the chat.
- **Double-click with the box open:** recording toggles as today, and the box stays exactly as it was. It must not close, then reopen, or flicker.
- **A recording is running:** the chat mic is disabled with the copy above. Typing still works.
- **No `~/Documents/nikxel/notes` folder, or a malformed filename:** the builder skips it with no crash.
- **Unpaired, or the dashboard down with no cache:** the answer still comes from local files, and the box shows "projects offline".

---

### Task 1: Server — `GET /api/device/projects/feed`

**Files:**
- Modify: `cloud/server/projects.js`. Factor the per-project day-building out of `GET /projects/:id` into `projectDays(db, orgId, p, names)`, used by both routes.
- Test: `cloud/server/projects.test.js` (extend)

**Interfaces:**
- Produces: `GET /api/device/projects/feed?days=N` with device auth.
  - It returns `[{id, name, days:[{date, meetings:[{title, body, name}], items:[{what, section, name}]}]}]`.
  - It covers the paired user's non-archived projects they're a member of, ordered by name.
  - `days` defaults to 14 and is clamped to 1–60. Only days with `date >= today - (days-1)` (UTC `YYYY-MM-DD`) are kept, newest first.

- [ ] **Step 1: Write the failing test** `device feed: own projects, window, clamp`.
  - The device for memA, a member of P1, has dated items and a meeting share today and 20 days ago. memA is not a member of P2.
  - `?days=14` returns P1 only, containing today's meeting and items but not the 20-day-old ones.
  - An archived project is absent.
  - `?days=999` behaves as 60 and `?days=abc` as 14.
  - With no bearer it returns 401.
- [ ] **Step 2: Run** `cd cloud/server && npm test`. Expect FAIL (404 on the route).
- [ ] **Step 3: Implement** the route and the `projectDays` refactor. Register the route before any `/projects/:id`-style device routes that could shadow it.
- [ ] **Step 4: Run** `npm test`. Expect all to pass, including the existing 38.
- [ ] **Step 5: Commit** `feat(server): device project feed for chat context`.

### Task 2: Context builder and feed fetch (both platforms) + agent timeout

**Files:**
- **Create `src/ChatContext.swift`** (Foundation only, so the check compiles standalone): `enum ChatContext` with
  - `static let cap: Int`
  - `static func localBlocks(root: URL, today: Date, days: Int = 14) -> [Block]`
  - `static func projectBlocks(_ feed: [[String: Any]]) -> [Block]`
  - `static func build(_ blocks: [Block], cap: Int) -> String`
  - `static func prompt(context: String, history: [(q: String, a: String)], question: String, today: Date) -> String`
  - `struct Block { kind, date, name, text }`
- **Modify `src/CloudSync.swift`:** add `static func projectFeed(get: Getter = httpGet) -> (feed: [[String: Any]], offline: Bool)`. On success it caches to `~/.nikxel/project-feed.json`. On failure it reads the cache, and `offline` is true when neither is available. It returns `([], false)` when unpaired. Clear the cache in `pair` next to the projects cache.
- **Modify `src/MOMGenerator.swift`:** `runPrompt(_:kind:claudeModel:timeout: Double = MOMGenerator.timeoutSec)`, passed through to `executeAgent`.
- **Mirror on Windows:**
  - create `windows/src/main/system/chatContext.ts` (same names in camelCase);
  - `cloudSync.ts` gets `projectFeed()`;
  - `momGenerator.ts` `runPrompt(prompt, kind, claudeModel?, timeoutSec?)`.
- **Tests:** create `check_chat_context.swift`, with its `swiftc` line in the header comment as `check_cloud_sync.swift` has, compiling `src/ChatContext.swift src/CloudSync.swift`. Also `windows/src/checks/chatContext.test.ts`, and extend both cloudSync checks for `projectFeed`.

- [ ] **Step 1: Write failing checks (both platforms), in a temp root:**
  - `daily/<today>.md`, `meetings/<today-1>-101500.md`, `meetings/<today-1>-101500.transcript.txt`, `notes/<today-20>-0900.md`, `notes/junk.md`.
  - `localBlocks` returns 2 blocks: daily today, then the meeting. There's no transcript, no 20-day note and no junk.
  - A missing `notes/` folder doesn't crash.
  - `build` with `cap = 200`, given an old daily, a recent meeting and a recent daily, drops the old daily first. The output never exceeds the cap, and blocks start with `### meeting · 2026-…`.
  - `prompt` contains today's date, the previous Q/A and the question last.
  - `projectFeed`:
    - a fake getter returning JSON caches it, and a nil getter then returns the cache with `offline == false`;
    - no cache and a nil getter gives `offline == true`;
    - no token gives `([], false)`.
- [ ] **Step 2: Run** the swiftc line and `cd windows && npm run check`. Expect FAIL.
- [ ] **Step 3: Implement.** Prompt rules (wording is yours):
  - answer only from the context;
  - say plainly if it isn't there;
  - a few lines or bullets;
  - cite the meeting, person or date.
- [ ] **Step 4: Run both checks.** Expect PASS, with the existing Windows checks still passing.
- [ ] **Step 5: Measure and set the cap.**
  - Build the context from the real `~/Documents/nikxel` with caps of 80_000 and 250_000.
  - Run `claude -p --model haiku` on the question "what was discussed in my last meeting?" three times each, timing the wall clock.
  - Set `cap` (both platforms) to the larger value whose median is ≤ 10 s, or 80_000 if neither is.
  - Record the timings in the report.
- [ ] **Step 6: Commit** `feat: chat context builder, device project feed fetch, runPrompt timeout`.

### Task 3: Chat window and single-click gesture (both platforms)

**Files:**
- **Create `src/AvatarChat.swift`:** `final class AvatarChat` with `static func toggle(near avatar: NSRect, recording: () -> Bool)`.
  - A borderless, non-activating `NSPanel` with an `NSVisualEffectView` (`.hudWindow`) holding a `WKWebView` page:
    - a log;
    - an input;
    - a mic and a send button;
    - Esc to close.
  - JS bridge `nx`: `send(text)` → main builds the context (`ChatContext` + `CloudSync.projectFeed`) off the main thread and calls `runPrompt`, then resolves the answer. `mic start|stop` uses the `AVAudioRecorder` → `Transcriber` flow copied from EditChat, writing to `~/.nikxel/edits/chat-voice.wav`.
  - Session history lives in the instance and is dropped on close.
- **Modify `src/NikxelWindowController.swift`:** add `onSingleClick`.
  - Record the mouse-down location.
  - On `mouseUp`, if the press was on the avatar and moved less than 4 pt, schedule `onSingleClick` in 0.25 s.
  - A mouse-down with `clickCount >= 2` cancels the pending work item before calling `onDoubleClick`.
- **Modify `src/NikxelApp.swift`:** wire `window.onSingleClick` to `AvatarChat.toggle(near: avatar frame, recording: { meetingCoordinator.isRecording })`. Expose `isRecording` if needed.
- **Mirror on Windows:**
  - `renderer/avatar.ts` posts `{type: "click"}` under the same 4 pt / 0.25 s rule (`e.detail >= 2` cancels it);
  - `avatarWindow.ts` handles `"click"` → `handlers.onClick`;
  - create `windows/src/main/system/avatarChat.ts` (a frameless, transparent, `alwaysOnTop` `BrowserWindow` positioned beside the avatar window, with IPC `chat:send`/`chat:voice` following `pageEdit.ts`'s pattern);
  - create `windows/src/renderer/avatarChat.html` + `avatarChat.ts` and `windows/src/preload/avatarChat.ts`;
  - wire it in `main.ts`.
- **Test:** both platforms get a pure `clickDecision(moved: Double, secondClick: Bool) -> .chat | .none` or equivalent, covered by the existing checks (`check_chat_context.swift`, `chatContext.test.ts`).

- [ ] **Step 1: Write failing checks.**
  - 0 pt with no second click gives chat.
  - 5 pt gives none.
  - A second click gives none.
  - 3.9 pt gives chat.
- [ ] **Step 2: Run.** Expect FAIL.
- [ ] **Step 3: Implement.** Load the `frontend-design` skill for the box page, matching Nikxel's existing Edit chat look but smaller and translucent.
- [ ] **Step 4: Verify.**
  - Run `./build.sh` and both checks, and `cd windows && npm run check`.
  - Relaunch `Nikxel.app`, then:
    - click the avatar and the box appears;
    - ask "what was discussed in my last meeting?" and an answer arrives in the box;
    - press Esc and the box closes;
    - drag the avatar and no box appears;
    - double-click and recording toggles with no box.
  - Report the observed answer time.
- [ ] **Step 5: Commit** `feat: click Nikxel to chat about your work (Mac + Windows)`.
