# Send Your Day to the Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The 10pm daily summary page becomes the place where the user picks what to share. They cross out items, press **Send to dashboard**, and the dashboard shows each person's day in detail: work, meetings, learning, research, shipping, chats and open tasks. Each item has a type, details and time.

**Architecture:** Nothing leaves the computer automatically any more. At 10pm the summary prompt tags each bullet with a hidden `[type]`. The daily page lets the user cross out bullets and has a Send button. The button calls Nikxel over the existing localhost server (PageShare, port 47120). Nikxel turns the `.md` into items, leaves out the crossed-out ones, and POSTs one `kind: "day"` summary. The cloud server replaces that day on every send and shows it at once: the sender sees it, and the org's owner and admins see it. The pending, redact and release flow is removed. Roles are read from the database on every request, not from the cookie, so promoting or demoting someone takes effect immediately.

**Tech Stack:** Swift (macOS app, `src/`), TypeScript/Electron (`windows/`), Node 22 + Express 5 + better-sqlite3 (`cloud/server`), React 18 + Vite + Tailwind 4 (`cloud/dashboard`).

**Spec:** the user's request of 2026-11-21 (in this session) plus their answers:
- Sendable: **everything** in the daily summary, including WhatsApp, Slack and open tasks. The user crosses out what they don't want sent.
- Admins: **owner and admins** can make admins (invite or promote). Members never can.
- Re-send: **replaces** that day on the dashboard.
- Categories: **tagged at 10pm** by the summary prompt, hidden on the user's page.

## Global Constraints

- Every `src/*.swift` change gets the same change in `windows/` in the same commit (memory: mirror-swift-changes-to-windows).
- Item types, exactly: `coding`, `shipped`, `meeting`, `research`, `learning`, `writing`, `review`, `planning`, `comms`, `other`. The server maps anything else to `other`.
- Wire item shape: `{ id: string, section: string, what: string, type: string, minutes: number, details: string[] }`. `section` is the lowercased `##` heading (e.g. `"what you worked on"`, `"meetings"`, `"open tasks"`). `id` is the first 12 hex characters of SHA-256 of `section + "\n" + what.lowercased()`.
- Push body, exactly: `{ kind: "day", date: "YYYY-MM-DD", headline: string, items: Item[] }`, with the device token as bearer.
- Nothing is pushed at 10pm. The only push is the user pressing Send.
- Only daily pages (`~/Documents/nikxel/daily/*.html`) get the cross-out and the Send button. Weekly pages don't.
- New dependencies: none.

## Review Focus

- **Pressing Send with Nikxel not paired:** the button says "Connect Nikxel to the dashboard first (menu → Connect to Dashboard…)" and nothing is sent. Test in Task 4.
- **Re-sending after un-crossing an item:** the dashboard shows the item again, because send replaces and doesn't merge. Test in Task 2.
- **An admin demoted while still signed in:** their next `/rollup` call returns 403, without waiting 7 days for the cookie to expire. Test in Task 1.
- **An admin trying to change the owner's role, or a member calling the promote route:** 403. Test in Task 1.
- **A summary written before this change (no `[type]` tags):** items arrive as `type: "other"` (or `meeting` for the Meetings section), and the page still renders and sends. Test in Task 3.

---

### Task 1: Server — roles from the database, admins make admins, logout

**Files:**
- Modify: `cloud/server/auth.js` (`requireRole`)
- Modify: `cloud/server/routes.js` (`/me`, `/invites`, new `PATCH /members/:userId`, new `POST /auth/logout`)
- Test: `cloud/server/routes.test.js`

**Interfaces:**
- Produces: `requireRole(db, ...roles)`. The role comes from `memberships` for `(session.userId, session.orgId)` and is set on `req.session.role`. `POST /api/auth/logout` → `{ok:true}`, clears `nikxel_session`. `PATCH /api/members/:userId` body `{role:'admin'|'member'}` → `{user_id, role}`. `/me` returns the role from the database.

- [ ] **Step 1: Write failing tests** in `routes.test.js`:
  - `admin can invite an admin`: `POST /api/invites {role:'admin'}` as admA → 200, `json.role === 'admin'`.
  - `member cannot invite admin`: as memA → 403.
  - `admin promotes member`: `PATCH /api/members/memA {role:'admin'}` as admA → 200. Then `GET /api/rollup` with memA's **old member cookie** → 200.
  - `demoted admin loses access now`: as owA, `PATCH /api/members/admA {role:'member'}` → 200. Then `GET /api/rollup` with admA's old admin cookie → 403.
  - `nobody changes the owner`: `PATCH /api/members/owA {role:'member'}` as admA → 403.
  - `cross-org promote is 404`: as owB, `PATCH /api/members/memA` → 404.
  - `logout clears cookie`: `POST /api/auth/logout` → 200, and the `set-cookie` header contains `nikxel_session=;`.
- [ ] **Step 2: Run** `cd cloud/server && npm test`. Expect the new tests to FAIL.
- [ ] **Step 3: Implement.** `requireRole` becomes a factory that takes `db`. Update every call site in `routes.js`. Drop the `role !== 'owner'` check on admin invites. In `PATCH /members/:userId`, the target must be in `req.session.orgId` (404 otherwise), the target's current role must not be `owner` (403), and the new role must be in `['admin','member']` (400). Logout uses `res.clearCookie('nikxel_session', {path:'/'})`, with the same options `issueSession` uses.
- [ ] **Step 4: Run** `npm test`. Expect all PASS.
- [ ] **Step 5: Commit** `feat(cloud): admins can make admins, roles read live, logout`.

### Task 2: Server — `day` summaries replace on send; remove redact/release

**Files:**
- Modify: `cloud/server/routes.js` (`POST /summaries`, `GET /summaries/mine`, `GET /rollup`; delete `/summaries/:id/redact`, `/release`, `PATCH /summaries/:id/items/:itemId`)
- Modify: `cloud/server/summaries.js`: delete `mergeItems`, `adminView`, `redact`, `ownerEdit` and `release`, and add `cleanDay(body) -> {date, headline, items}`, which throws `status 400` on bad input
- Modify: `cloud/server/summaries.test.js`, `cloud/server/routes.test.js` (remove the tests for the deleted functions)
- Modify: `cloud/server/seed.js`, so it seeds `kind:'day'` rows using the new item shape, across several sections and types, for each dev person and for 2026-11-19 and 2026-11-20

**Interfaces:**
- Consumes: Task 1's `requireRole(db, ...)`.
- Produces: `GET /api/summaries/mine` → `[{id, date, headline, items, created_at}]`, newest first, `kind='day'` only. `GET /api/rollup` (owner/admin) → `[{date, user_id, name, headline, items}]`, newest first. `name` is `users.name ?? users.email`.

- [ ] **Step 1: Write failing tests:**
  - `cleanDay` (summaries.test.js): rejects a bad date `'2026-13-99x'`. Maps type `'gaming'` to `'other'`. Trims `details` to 20 strings, and drops non-strings from it. Rejects `what` longer than 1000 characters. Keeps only `{id, section, what, type, minutes, details}`.
  - `send replaces the day` (routes.test.js): as memA's device, push `items:[A,B]`, then push `items:[A]`. `GET /summaries/mine` as memA → exactly one row for that date, whose items are `[A]`.
  - `rollup shows sent day immediately, with name`: after the push, `GET /rollup` as admA → a row with `name === 'memA'` and `headline` echoed.
  - `member cannot read rollup` → 403. `org B cannot see org A`: rollup as owB has no memA rows.
  - `old routes gone`: `POST /api/summaries/x/release` → 404.
- [ ] **Step 2: Run** `npm test`. Expect FAIL.
- [ ] **Step 3: Implement.** `POST /summaries` requires `kind === 'day'`, runs `cleanDay`, then upserts on `(user_id, org_id, 'day', date)`: `INSERT … ON CONFLICT DO UPDATE SET items, notes=headline, created_at`. Store `status='sent'` and `visibility='admin'`. The table is unchanged.
- [ ] **Step 4: Run** `npm test && node seed.js`. Expect PASS, and the seed runs cleanly on a fresh `DB_PATH=/tmp/x.db`.
- [ ] **Step 5: Commit** `feat(cloud): day summaries replace on send; drop redact/release`.

### Task 3: Desktop — turn a daily `.md` into day items (mac + windows)

**Files:**
- Modify: `src/CloudSync.swift`: replace `WorkItem`/`workItems`/`pushDaily` with `DayItem`, `dayItems` and `pushDay`
- Modify: `windows/src/main/system/cloudSync.ts` (same)
- Modify: `src/DayLogger.swift:618` and `windows/src/main/system/dayLogger.ts:665`: **delete** the 10pm `pushDaily` call
- Test: `check_cloud_sync.swift`, `windows/src/checks/cloudSync.test.ts`

**Interfaces:**
- Produces (Swift): `struct DayItem: Equatable { id, section, what, type: String; minutes: Int; details: [String] }`. `static func dayItems(fromDailySummary md: String) -> (headline: String, items: [DayItem])`. `static func pushDay(summary: String, day: String, skip: Set<String>, post: Poster = httpPost) -> Bool`, which is false when there's no token, no items or a failed POST.
- Produces (TS): the same names. `pushDay(...)` returns `Promise<boolean>`.

Rules: every `## ` section except `Summary` contributes its **top-level** bullets. Indented bullets under one become its `details`, with the leading `- ` and `**` removed. Bullets that are `isNone`, or that start with "nothing", "no calls", or "no tasks", are skipped. A leading `[type]` tag sets `type` and is removed from `what`. With no tag, the type is `meeting` in the Meetings section and `other` everywhere else. Minutes come from the existing duration regex, run on the top-level text. `headline` is the first paragraph under `## Summary`.

- [ ] **Step 1: Rewrite the checks** with this summary:
  `## Summary\nBig day on the dashboard.\n\n## What you worked on\n- [coding] **Fixed typing lag** — 1h 30m\n  - found the missing tap re-enable\n- Planning Q4 ~2h\n\n## Meetings\n- 10:30 — Standup 15m\n- None today.\n\n## WhatsApp\n- No calls today.\n- Ravi asked you to send the deck — open\n\n## Open tasks\n- Send deck — for Ravi — open`
  Assert: `headline == "Big day on the dashboard."`. There are 5 items. Item 0 is `{section:"what you worked on", what:"Fixed typing lag", type:"coding", minutes:90, details:["found the missing tap re-enable"]}`. Item 1 has `type "other"` and `minutes 120`. The Meetings item has `type "meeting"`. The id is stable across two calls and differs between sections that contain the same text. `pushDay` with no token → false, and the poster is never called. `pushDay` with a token and `skip:[item0.id]` → the body's `kind=="day"` and its items don't contain item0. The 10pm path no longer references CloudSync: `grep -c pushDaily src/DayLogger.swift` returns 0.
- [ ] **Step 2: Run** `swiftc -parse-as-library -target arm64-apple-macos15.0 -o /tmp/ccs src/CloudSync.swift src/NoteExporter.swift check_cloud_sync.swift && /tmp/ccs` (add whatever `NoteExporter` needs to compile, or inline `isNone`), and `cd windows && npx tsx --test src/checks/cloudSync.test.ts`. Expect FAIL.
- [ ] **Step 3: Implement** both parsers.
- [ ] **Step 4: Run** both checks. Expect PASS, and `npx tsc --noEmit -p windows` is clean.
- [ ] **Step 5: Commit** `feat(desktop): day items from the daily summary; no auto-push (mac + windows)`.

### Task 4: Desktop — tags at 10pm, cross-out and Send on the daily page (mac + windows)

**Files:**
- Modify: `src/DayLogger.swift` (summary prompt near line 1180) and `windows/src/main/system/dayLogger.ts` (the same prompt). Add to the prompt's rules: *"Start every top-level bullet in What you worked on, Meetings, Browsing & Reading and Other with one tag from [coding] [shipped] [meeting] [research] [learning] [writing] [review] [planning] [comms] [other], e.g. `- [research] Compared three OCR libraries…`. Pick [shipped] for a push, release or deploy."*
- Modify: `src/DayPage.swift`, `windows/src/main/system/dayPage.ts`. `html(from:)` first removes tags: `(?m)^(\s*[-*] )\[[a-z]+\] ` → `$1`. With a new `daily: Bool` parameter (true only from the 10pm/daily writer), every top-level `<li>` in every section except Summary gets `data-id="<DayItem id>"`, computed with `CloudSync`'s id function on the tag-free text. The page also gets a bar above the footer: `<div class="nx-send" hidden><p>Cross out anything you don't want to share, then send.</p><button>Send to dashboard</button><span class="nx-sent"></span></div>`. Crossed items use the CSS `.x { text-decoration: line-through; opacity: .45 }`.
- Modify: `src/PageShare.swift`, `windows/src/main/system/pageShare.ts`. Add two routes, both limited to files whose parent folder is `daily`:
  - `/dashboard-state` → `{paired: Bool, skip: [String], sentAt: Double?}`, read from `<stem>.sent.json` beside the page.
  - `/dashboard?skip=a,b` → `CloudSync.pushDay(summary: md, day: stem, skip:)`. On success it writes `<stem>.sent.json` `{skip, sentAt}` and returns `{ok:true}`. When not paired it returns `{error:"Connect Nikxel to the dashboard first (menu → Connect to Dashboard…)"}`. On failure it returns `{error:"Couldn't reach the dashboard. Try again."}`. It runs off the listener queue (`DispatchQueue.global`), because `pushDay` blocks for up to 20s; the response is sent from the completion.
  - Widget JS (same template in both files): if `.nx-send` exists, call `dashboard-state`, unhide the bar, apply `.x` to the `skip` ids, and show "Sent HH:MM" when `sentAt` is set. Clicking an `li[data-id]` (not a link, not a checkbox) toggles `.x`. Send collects the `.x` ids, calls `dashboard`, and shows "Sending…", then "Sent ✓ HH:MM" or the error. Bump the marker `nxw4` → `nxw5` in the template and in `migrateWidgets` (both platforms), so pages written before today get the new widget.
- Modify: `src/DayLogger.swift:609` and the matching TS call. Pass `daily: true`.
- Test: `check_cloud_sync.swift` (or a new `check_day_page.swift` in the same style) and `windows/src/checks/dayPage.test.ts`.

**Interfaces:**
- Consumes: `CloudSync.dayItems`, `CloudSync.pushDay`, and a single id helper `CloudSync.itemID(section:what:) -> String` (pull it out in this task, and use it in `dayItems` too).

- [ ] **Step 1: Write failing tests** (TS, mirrored in Swift):
  - `DayPage.html(md, null, false, true)` for the Task 3 summary: contains no `[coding]`. Contains `data-id="<itemID('what you worked on','Fixed typing lag')>"`. Contains `class="nx-send"`.
  - The same call with `daily=false` contains neither `data-id` nor `nx-send`.
  - The open-task checkbox still renders (`class="nx-todo"`), so it doesn't conflict with yesterday's change.
- [ ] **Step 2: Run** the checks. Expect FAIL.
- [ ] **Step 3: Implement** the prompt line, the rendering, the routes and the widget JS.
- [ ] **Step 4: Run** the checks, then `./build.sh` and restart the app. Open today's `daily/*.html`. Unpaired, Send shows the "Connect Nikxel…" error. After pairing against `cd cloud/server && DEV_LOGIN=1 SESSION_SECRET=… node app.js`, crossing out one item and sending makes the day appear in the dashboard without that item. Un-crossing it and sending again brings it back. Reloading the page keeps the crossings.
- [ ] **Step 5: Commit** `feat(desktop): cross out and send the day to the dashboard (mac + windows)`.

### Task 5: Dashboard — logout, read-only "My days", "Team", promote, and the redesign

**Files:**
- Modify: `cloud/dashboard/src/api.js`: add `logout`, `setRole(userId, role)`; remove `redact`, `release`, `editItem`, `canEditFacts`
- Modify: `cloud/dashboard/src/App.jsx` (tabs: `My days`, `Team` (admin), `People` (admin), `Connect`; a **Log out** button in the nav that calls `api.logout()` then `setMe(null)`)
- Rewrite: `cloud/dashboard/src/screens/Mine.jsx` (read-only, with no Remove or Release), `Admin.jsx` → `Team.jsx`
- Create: `cloud/dashboard/src/screens/Day.jsx`, the one component both screens use to render a day
- Modify: `cloud/dashboard/src/screens/People.jsx`: role select for owner **and** admin, plus a "Make admin" / "Make member" button per non-owner row
- Test: `cloud/dashboard/src/api.test.js` (add a `typeMeta` test)

**Interfaces:**
- Consumes: Task 1 and Task 2 routes.
- Produces: `Day({ day: {date, headline, items, name?} })`. `typeMeta(type) -> {label, color, icon}` in `Day.jsx`, exported for the test, covering all 10 types plus a fallback.

Design (load `frontend-design` before writing): each day is a card. The header shows the date as "Thursday, 20 Nov" with the person's name on Team, the headline in a larger serif, and a horizontal stacked bar of minutes per type with a legend ("2h 10m coding · 45m meetings · 30m research"). The body groups items by section in daily-summary order. Each item shows a colored type chip with an icon, the `what` text, and minutes right-aligned when greater than 0. `details` collapse under a "more" toggle. Open tasks show their open/done status as a pill. Team has a person filter (All / each name) and a date filter (the last 14 days with data), and the newest day is open by default. The design must look right in light and dark (`prefers-color-scheme`) and at 375px wide.

- [ ] **Step 1: Write a failing test**: `typeMeta('coding').label === 'Coding'`, `typeMeta('shipped').label === 'Shipped'`, and `typeMeta('nope').label === 'Other'`.
- [ ] **Step 2: Run** `cd cloud/dashboard && npm test`. Expect FAIL.
- [ ] **Step 3: Implement** the screens.
- [ ] **Step 4: Run** `npm test && npm run build`, then `node ../server/seed.js` and `npm run dev`. Dev-sign in as Ben (member): only "My days" and "Connect", no Remove buttons, and Log out returns to sign-in. As Asha (admin): Team shows everyone's days with the type bars, and People can make Ben an admin. Ben's next page load (no re-login) shows Team.
- [ ] **Step 5: Commit** `feat(dashboard): detailed day view, team view, logout, admins promote`.
